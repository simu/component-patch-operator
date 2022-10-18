std.trace(
  'importing resource-locker.libjsonnet is deprecated, ' +
  "please switch to `import 'patch-operator.libsonnet'`. " +
  'See https://hub.syn.tools/patch-operator/how-tos/migrating-from-resource-locker.html for more details.',
  import 'patch-operator.libsonnet'
)
