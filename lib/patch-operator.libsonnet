/**
 * \file Library with public methods provided by component patch-operator.
 */

local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local inv = kap.inventory();
local patch_operator_params = inv.parameters.patch_operator;
local namespace = patch_operator_params.namespace;
local instance = inv.parameters._instance;

local apiVersion = 'redhatcop.redhat.io/v1alpha1';

local defaultSaRef = {

};

local obj_data(obj) =
  local apigrp = std.split(obj.apiVersion, '/')[0];
  {
    apiVersion: obj.apiVersion,
    apigroup:: if apigrp == 'v1' then '' else apigrp,
    kind: obj.kind,
    name: obj.metadata.name,
    namespace: if std.objectHas(obj.metadata, 'namespace') then obj.metadata.namespace,
  };

local replaceColon(str) =
  std.strReplace(str, ':', '-');

local rl_obj_name(objdata) =
  // Some objects like ClusterRoleBinding can contain colons.
  local name = replaceColon(objdata.name);
  local unhashed = '%s-%s-%s-%s-%s' % [ instance, objdata.kind, objdata.apigroup, objdata.namespace, name ];
  // Take 15 characters of the md5 hash, to leave room for a human-readable
  // prefix.
  local hashed = std.substr(std.md5(unhashed), 0, 15);

  local prefix =
    local p =
      if objdata.namespace != null then
        // for namespaced objects, use `<ns>-<name>` as the prefix
        '%s-%s' % [ std.asciiLower(objdata.namespace), name ]
      else
        // for cluster-scoped objects, use `<kind>-<name>` as the prefix
        // We could also add `<apigroup>` in the prefix, but we don't
        // need to do this, since the apigroup is part of the hashed string.
        '%s-%s' % [ std.asciiLower(objdata.kind), name ];
    // Trim the prefix if it's too long, make sure the kind/namespace part of
    // the prefix remains.
    if std.length(p) > 31 then
      std.substr(p, 0, 31)
    else
      p;

  local n = '%s-%s' % [ prefix, hashed ];

  // We generate names with a max length of 47, so there's a few characters
  // left for adding `manager` in `clusterRoleName()` and `saname`.
  assert
    std.length(n) <= 47 :
    "name generated by rl_obj_name() is longer than 47 characters, this shouldn't happen";
  n;

local clusterRoleName(name) =
  local prefix = namespace + '-';
  local suffix = '-manager';
  local maxLength = 63 - std.length(prefix) - std.length(suffix);
  local nameLength = std.length(name);
  local start = nameLength - std.min(maxLength, std.length(name));
  prefix + std.substr(name, start, nameLength) + suffix;


local rbac_objs(objdata, verbs=[ 'create', 'get', 'update', 'patch' ]) =
  local dest_ns = objdata.namespace;
  // Use full rl_obj_name to avoid collisions for cluster-scoped configs
  local name = rl_obj_name(objdata);
  // Create sa if not provided
  // Append '-manager' to sa name if we have room
  local saname =
    local n = name + '-manager';
    if std.length(n) > 63 then name else n;
  // Add human-readable information about the resource locker target to RBAC
  // objects as labels and annotations.
  local rbac_meta = {
    annotations+: {
      'resourcelocker.syn.tools/target-object':
        if objdata.apigroup != '' then
          '%(apigroup)s.%(kind)s/%(name)s' % objdata
        else
          '%(kind)s/%(name)s' % objdata,
      // We don't have to check if namespace is != null here, as we prune all
      // objects anyway.
      'resourcelocker.syn.tools/target-namespace': objdata.namespace,
    },
    labels+: {
      'app.kubernetes.io/managed-by': 'commodore',
      'app.kubernetes.io/part-of': instance,
    },
  };
  local serviceaccount = kube.ServiceAccount(saname) {
    metadata+: rbac_meta {
      namespace: namespace,
    },
    secrets: [ { name: saname } ],
  };
  // Create service account token secret
  local tokensecret = kube.Secret(saname) {
    metadata+: rbac_meta {
      namespace: namespace,
      annotations+: {
        'kubernetes.io/service-account.name': saname,
      },
    },
    type: 'kubernetes.io/service-account-token',
  };
  // Create cluster role to get/list/watch resource kind
  local rolename = clusterRoleName(name);
  local res = std.asciiLower(objdata.kind);
  local suffix = if std.endsWith(res, 's') then 'es' else 's';
  local resource = res + suffix;
  local clusterrole_extra_verbs = if dest_ns == null then verbs else [];
  local clusterrole = kube.ClusterRole(rolename) {
    metadata+: rbac_meta,
    rules+: [ {
      apiGroups: [ objdata.apigroup ],
      resources: [ resource ],
      verbs: std.setUnion([ 'list', 'watch' ], clusterrole_extra_verbs),
    } ],
  };
  local clusterrolebinding = kube.ClusterRoleBinding(rolename) {
    metadata+: rbac_meta,
    subjects_: [ serviceaccount ],
    roleRef_: clusterrole,
  };
  // Create role in destination namespace to allow managing the resource kind
  local role = if dest_ns != null then kube.Role(rolename) {
    metadata+: rbac_meta {
      namespace: dest_ns,
    },
    rules+: [ {
      apiGroups: [ objdata.apigroup ],
      resources: [ resource ],
      verbs: verbs,
    } ],
  };
  local rolebinding = if dest_ns != null then kube.RoleBinding(rolename) {
    metadata+: rbac_meta {
      namespace: dest_ns,
    },
    subjects_: [ serviceaccount ],
    roleRef_: role,
  };
  {
    serviceaccount: serviceaccount,
    objs: std.prune([
      serviceaccount,
      tokensecret,
      clusterrole,
      clusterrolebinding,
      role,
      rolebinding,
    ]),
  };


local render_patch(patch, rl_version, patch_id='patch1') =
  { [patch_id]: patch };

local patch(name, saName, targetobjref, patchtemplate, patchtype='application/strategic-merge-patch+json') =
  kube._Object(apiVersion, 'Patch', name) {
    metadata+: {
      namespace: namespace,
    },
    spec+: {
      serviceAccountRef: {
        name: saName,
      },
      patches: {
        patch1: {
          targetObjectRef: targetobjref,
          patchTemplate: std.manifestYamlDoc(patchtemplate),
          patchType: patchtype,
        },
      },
    },
  };

local Patch(targetobj, patchtemplate, patchstrategy='application/strategic-merge-patch+json') =
  local objdata = obj_data(targetobj);
  local rbac = rbac_objs(objdata, verbs=[ 'get', 'patch' ]);
  local name = rl_obj_name(objdata);
  rbac.objs + [
    patch(
      name,
      rbac.serviceaccount.metadata.name,
      std.prune(objdata),
      patchtemplate,
      patchstrategy
    ),
  ];

local Resource(obj) =
  error "patch-operator doesn't support kind `Resource`, please manage full resources directly in your component";

{
  apiVersion: apiVersion,
  Resource: Resource,
  Patch: Patch,
  renderPatch: render_patch,
}
