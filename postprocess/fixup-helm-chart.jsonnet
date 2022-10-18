local com = import 'lib/commodore.libjsonnet';

local manifests_dir = std.extVar('output_path');

local fixupFn(obj) =
  if obj.kind == 'Service' then
    local secretName =
      obj.metadata.annotations['service.alpha.openshift.io/serving-cert-secret-name'];
    obj {
      metadata+: {
        annotations+: {
          'service.alpha.openshift.io/serving-cert-secret-name': 'ocp-%s' % [ secretName ],
        },
      },
    }
  else
    obj;

com.fixupDir(manifests_dir, fixupFn)
