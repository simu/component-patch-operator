local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.patch_operator;
local argocd = import 'lib/argocd.libjsonnet';

local app = argocd.App('patch-operator', params.namespace);

{
  'patch-operator': app,
}
