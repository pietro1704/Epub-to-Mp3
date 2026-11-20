#ifndef RUNNER_BOOK_IMPORT_H_
#define RUNNER_BOOK_IMPORT_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

void book_import_connect(FlView* view, FlValue* pending);
void book_import_enqueue(FlView* view, FlValue* pending, FlValue* paths,
                         bool open_in_reader);

#endif  // RUNNER_BOOK_IMPORT_H_
