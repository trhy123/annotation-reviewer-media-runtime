/* Validate the redistributed libmpv without linker search-path overrides.
 * Usage: mpv_dlopen_smoke /absolute/path/to/libmpv.2.dylib
 */
#include <dlfcn.h>
#include <locale.h>
#include <stdio.h>
#include <stdlib.h>

typedef void *(*mpv_create_fn)(void);
typedef int (*mpv_initialize_fn)(void *);
typedef void (*mpv_destroy_fn)(void *);
typedef unsigned long (*mpv_client_api_version_fn)(void);

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s /absolute/path/to/libmpv.dylib\n", argv[0]);
        return 2;
    }
    if (!setlocale(LC_NUMERIC, "C")) {
        fputs("Unable to set LC_NUMERIC=C\n", stderr);
        return 3;
    }
    void *lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!lib) {
        fprintf(stderr, "dlopen(%s): %s\n", argv[1], dlerror());
        return 4;
    }
    mpv_create_fn create = (mpv_create_fn)dlsym(lib, "mpv_create");
    mpv_initialize_fn initialize = (mpv_initialize_fn)dlsym(lib, "mpv_initialize");
    mpv_destroy_fn destroy = (mpv_destroy_fn)dlsym(lib, "mpv_terminate_destroy");
    mpv_client_api_version_fn version = (mpv_client_api_version_fn)dlsym(lib, "mpv_client_api_version");
    if (!create || !initialize || !destroy || !version ||
        !dlsym(lib, "mpv_render_context_create") ||
        !dlsym(lib, "mpv_render_context_render") ||
        !dlsym(lib, "mpv_render_context_free")) {
        fputs("Required libmpv client/render API symbols are missing\n", stderr);
        dlclose(lib);
        return 5;
    }
    if (!version()) {
        fputs("mpv_client_api_version returned 0\n", stderr);
        dlclose(lib);
        return 6;
    }
    void *handle = create();
    if (!handle) {
        fputs("mpv_create failed\n", stderr);
        dlclose(lib);
        return 7;
    }
    int status = initialize(handle);
    if (status < 0) {
        fprintf(stderr, "mpv_initialize returned %d\n", status);
    }
    destroy(handle);
    dlclose(lib);
    return status < 0 ? 8 : 0;
}
