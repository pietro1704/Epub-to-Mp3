module WorkspaceHelper
  WorkspaceTab = Data.define(:id, :selected, :enabled) do
    def trigger_id = "tab-#{id}"
    def panel_id = "panel-#{id}"
  end

  # Before any job exists only setup is reachable, as in the React client.
  def workspace_tabs
    %w[setup progress downloads].map { |id| WorkspaceTab.new(id: id, selected: id == "setup", enabled: id == "setup") }
  end

  def workspace_tab_classes(tab)
    class_names("tabs__trigger", "tabs__trigger--active": tab.selected, "tabs__trigger--disabled": !tab.enabled)
  end
end
