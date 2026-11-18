class WorkspaceController < ApplicationController
  # Jobs, audio and books live only in the browser, so there is nothing to
  # load: the document carries markup and strings for the browser runtime.
  def show
  end
end
