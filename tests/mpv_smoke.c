#include <mpv/client.h>
#include <mpv/render.h>

int main(void) {
    mpv_handle *ctx = mpv_create();
    if (!ctx) {
        return 2;
    }

    if (mpv_client_api_version() == 0) {
        mpv_terminate_destroy(ctx);
        return 3;
    }

    /* Force the linker/loader to resolve the render API used by Annotation Reviewer. */
    int (*render_create)(mpv_render_context **, mpv_handle *, mpv_render_param *) =
        mpv_render_context_create;
    if (!render_create) {
        mpv_terminate_destroy(ctx);
        return 4;
    }

    mpv_terminate_destroy(ctx);
    return 0;
}
