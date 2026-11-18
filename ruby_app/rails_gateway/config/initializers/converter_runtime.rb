# Be sure to restart your server when you modify this file.

# Publishes the generated runtime tree and the cache policy for static files.
runtime_settings = Rails.application.config.x.converter_runtime
runtime_tree = ConverterRuntime::Tree.new(manifest_path: runtime_settings.manifest_path, root: runtime_settings.root)
runtime_settings.tree = runtime_tree

Rails.application.config.middleware.insert_before ActionDispatch::Static, ResponsePolicy::ImmutableAssets
Rails.application.config.middleware.insert_before ActionDispatch::Static, ConverterRuntime::FileServer, runtime_tree
