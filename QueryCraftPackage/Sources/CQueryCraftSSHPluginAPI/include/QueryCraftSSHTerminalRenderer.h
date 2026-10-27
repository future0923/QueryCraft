#ifndef QUERYCRAFT_SSH_TERMINAL_RENDERER_H
#define QUERYCRAFT_SSH_TERMINAL_RENDERER_H
#include <stddef.h>
#include <stdint.h>
/* Optional local macOS UI component. ALL calls and callbacks run on the main
   thread. No SSH, credentials, files or Swift metadata cross this boundary.
   create copies callbacks; context must outlive destroy. view returns a borrowed
   NSView pointer; create/destroy own the opaque renderer. Byte/title pointers
   live only during the callback/call. Keep loaded code resident until exit. */
#define QC_SSH_TERMINAL_RENDERER_ABI_VERSION 1
#define QC_SSH_TERMINAL_RENDERER_MAX_FEED 65536
#define QC_SSH_TERMINAL_RENDERER_MAX_TEXT 65536
typedef void (*qc_terminal_input_callback)(void *, const uint8_t *, size_t);
typedef void (*qc_terminal_resize_callback)(void *, uint32_t, uint32_t);
typedef void (*qc_terminal_title_callback)(void *, const uint8_t *, size_t);
typedef struct {
    uint32_t size;
    qc_terminal_input_callback input;
    qc_terminal_resize_callback resize;
    qc_terminal_title_callback title;
} qc_terminal_callbacks;
typedef uint32_t (*qc_terminal_renderer_version_fn)(void);
typedef void *(*qc_terminal_renderer_create_fn)(const qc_terminal_callbacks *, void *);
typedef void *(*qc_terminal_renderer_view_fn)(void *);
typedef void (*qc_terminal_renderer_feed_fn)(void *, const uint8_t *, size_t);
typedef void (*qc_terminal_renderer_appearance_fn)(void *, uint32_t dark);
typedef uint32_t (*qc_terminal_renderer_dimension_fn)(void *);
typedef size_t (*qc_terminal_renderer_text_fn)(void *, uint8_t *, size_t);
typedef void (*qc_terminal_renderer_destroy_fn)(void *);
#endif
