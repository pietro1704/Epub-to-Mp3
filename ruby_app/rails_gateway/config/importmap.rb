# Page code is plain ES modules digested by Propshaft; there is no bundler.
# The generated conversion runtime is not pinned here: it is imported by URL
# from the un-digested tree under /runtime/<id>/ (see runtime/converter_runtime).

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
pin_all_from "app/javascript/runtime", under: "runtime"
