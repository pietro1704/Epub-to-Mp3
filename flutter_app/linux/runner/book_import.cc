#include "book_import.h"

namespace {
constexpr char kChannel[] = "epub_to_mp3/linux_book_import";

void AppendFile(FlValue* paths, GFile* file) {
  g_autofree gchar* path = g_file_get_path(file);
  if (!path) return;
  g_autofree gchar* lower = g_ascii_strdown(path, -1);
  if (g_str_has_suffix(lower, ".epub") || g_str_has_suffix(lower, ".pdf")) {
    fl_value_append_take(paths, fl_value_new_string(path));
  }
}

void AppendUris(FlValue* paths, gchar** uris) {
  for (gchar** uri = uris; uri && *uri; ++uri) {
    if (!g_str_has_prefix(*uri, "file:")) continue;
    g_autoptr(GFile) file = g_file_new_for_uri(*uri);
    AppendFile(paths, file);
  }
}

void Respond(FlMethodCall* call, FlValue* value) {
  g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
      fl_method_success_response_new(value));
  fl_method_call_respond(call, response, nullptr);
}

const char* StringArgument(FlMethodCall* call, const char* key) {
  FlValue* arguments = fl_method_call_get_args(call);
  if (!arguments || fl_value_get_type(arguments) != FL_VALUE_TYPE_MAP) return "";
  FlValue* value = fl_value_lookup_string(arguments, key);
  return value && fl_value_get_type(value) == FL_VALUE_TYPE_STRING
             ? fl_value_get_string(value) : "";
}

void FileChooserResponse(GtkDialog* dialog, gint response, FlMethodCall* call) {
  g_autoptr(FlValue) paths = fl_value_new_list();
  if (response == GTK_RESPONSE_ACCEPT) {
    GSList* files = gtk_file_chooser_get_files(GTK_FILE_CHOOSER(dialog));
    for (GSList* file = files; file; file = file->next) {
      AppendFile(paths, G_FILE(file->data));
    }
    g_slist_free_full(files, g_object_unref);
  }
  Respond(call, paths);
  gtk_widget_destroy(GTK_WIDGET(dialog));
}

void ChooseBooks(GtkWindow* window, FlMethodCall* call) {
  GtkWidget* dialog = gtk_file_chooser_dialog_new(
      StringArgument(call, "title"), window, GTK_FILE_CHOOSER_ACTION_OPEN,
      StringArgument(call, "cancel"), GTK_RESPONSE_CANCEL,
      StringArgument(call, "accept"), GTK_RESPONSE_ACCEPT, nullptr);
  gtk_window_set_modal(GTK_WINDOW(dialog), TRUE);
  gtk_window_set_destroy_with_parent(GTK_WINDOW(dialog), TRUE);
  gtk_dialog_set_default_response(GTK_DIALOG(dialog), GTK_RESPONSE_ACCEPT);
  gtk_file_chooser_set_select_multiple(GTK_FILE_CHOOSER(dialog), TRUE);
  gtk_file_chooser_set_local_only(GTK_FILE_CHOOSER(dialog), TRUE);
  GtkFileFilter* filter = gtk_file_filter_new();
  gtk_file_filter_set_name(filter, "EPUB / PDF");
  gtk_file_filter_add_mime_type(filter, "application/epub+zip");
  gtk_file_filter_add_mime_type(filter, "application/pdf");
  gtk_file_filter_add_pattern(filter, "*.epub");
  gtk_file_filter_add_pattern(filter, "*.pdf");
  gtk_file_chooser_add_filter(GTK_FILE_CHOOSER(dialog), filter);
  // Zero is the default connection mode on older GLib versions.
  g_signal_connect_data(dialog, "response", G_CALLBACK(FileChooserResponse),
                        g_object_ref(call),
                        [](gpointer data, GClosure*) { g_object_unref(data); },
                        static_cast<GConnectFlags>(0));
  gtk_widget_show(dialog);
}

void CopiedFilesReceived(GtkClipboard*, GtkSelectionData* selection,
                         gpointer data) {
  g_autoptr(FlMethodCall) call = FL_METHOD_CALL(data);
  g_autoptr(FlValue) paths = fl_value_new_list();
  const auto* bytes = gtk_selection_data_get_data(selection);
  gint length = gtk_selection_data_get_length(selection);
  if (bytes && length > 0) {
    g_autofree gchar* text = g_strndup(reinterpret_cast<const gchar*>(bytes),
                                     length);
    g_auto(GStrv) uris = g_uri_list_extract_uris(text);
    AppendUris(paths, uris);
  }
  Respond(call, paths);
}

void ClipboardUrisReceived(GtkClipboard* clipboard, gchar** uris,
                           gpointer data) {
  g_autoptr(FlMethodCall) call = FL_METHOD_CALL(data);
  g_autoptr(FlValue) paths = fl_value_new_list();
  AppendUris(paths, uris);
  if (fl_value_get_length(paths) > 0) {
    Respond(call, paths);
    return;
  }
  gtk_clipboard_request_contents(
      clipboard, gdk_atom_intern_static_string("x-special/gnome-copied-files"),
      CopiedFilesReceived, g_object_ref(call));
}

void MethodCall(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  auto* view = FL_VIEW(data);
  if (g_str_equal(fl_method_call_get_name(call), "chooseBooks")) {
    ChooseBooks(GTK_WINDOW(gtk_widget_get_toplevel(GTK_WIDGET(view))), call);
  } else if (g_str_equal(fl_method_call_get_name(call), "pasteBooks")) {
    gtk_clipboard_request_uris(
        gtk_widget_get_clipboard(GTK_WIDGET(view), GDK_SELECTION_CLIPBOARD),
        ClipboardUrisReceived, g_object_ref(call));
  } else if (g_str_equal(fl_method_call_get_name(call), "takePending")) {
    g_autoptr(FlValue) batches = static_cast<FlValue*>(
        g_object_steal_data(G_OBJECT(view), "book-import-pending"));
    g_object_set_data_full(G_OBJECT(view), "book-import-pending",
                           fl_value_new_list(),
                           [](gpointer queue) { fl_value_unref(static_cast<FlValue*>(queue)); });
    Respond(call, batches);
  } else {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    fl_method_call_respond(call, response, nullptr);
  }
}

void FilesDropped(GtkWidget* widget, GdkDragContext*, gint, gint,
                  GtkSelectionData* selection, guint, guint, gpointer) {
  auto* view = FL_VIEW(widget);
  g_auto(GStrv) uris = gtk_selection_data_get_uris(selection);
  g_autoptr(FlValue) paths = fl_value_new_list();
  AppendUris(paths, uris);
  book_import_enqueue(view, nullptr, paths, false);
}
}  // namespace

void book_import_connect(FlView* view, FlValue* pending) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)), kChannel,
      FL_METHOD_CODEC(codec));
  g_object_set_data_full(G_OBJECT(view), "book-import-channel", channel,
                         g_object_unref);
  g_object_set_data_full(G_OBJECT(view), "book-import-pending",
                         fl_value_ref(pending),
                         [](gpointer queue) { fl_value_unref(static_cast<FlValue*>(queue)); });
  fl_method_channel_set_method_call_handler(channel, MethodCall, view, nullptr);
  gtk_drag_dest_set(GTK_WIDGET(view), GTK_DEST_DEFAULT_ALL, nullptr, 0,
                    GDK_ACTION_COPY);
  gtk_drag_dest_add_uri_targets(GTK_WIDGET(view));
  g_signal_connect(view, "drag-data-received", G_CALLBACK(FilesDropped), nullptr);
}

void book_import_enqueue(FlView* view, FlValue* pending, FlValue* paths,
                         bool open_in_reader) {
  if (fl_value_get_length(paths) == 0) return;
  if (view) {
    pending = static_cast<FlValue*>(
        g_object_get_data(G_OBJECT(view), "book-import-pending"));
  }
  FlValue* batch = fl_value_new_map();
  fl_value_set_string(batch, "paths", paths);
  fl_value_set_string_take(batch, "open", fl_value_new_bool(open_in_reader));
  fl_value_append_take(pending, batch);
  if (view) {
    auto* channel = FL_METHOD_CHANNEL(
        g_object_get_data(G_OBJECT(view), "book-import-channel"));
    fl_method_channel_invoke_method(channel, "booksAvailable", nullptr, nullptr,
                                    nullptr, nullptr);
  }
}
