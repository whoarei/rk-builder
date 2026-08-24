#include <stdio.h>
#include <string.h>

#include <rknn_api.h>

int main(int argc, char *argv[])
{
    rknn_context context = 0;
    rknn_sdk_version version;
    int ret;

    if (argc != 2) {
        fprintf(stderr, "Usage: %s MODEL.rknn\n", argv[0]);
        return 2;
    }

    ret = rknn_init(&context, argv[1], 0, 0, NULL);
    if (ret != RKNN_SUCC) {
        fprintf(stderr, "rknn_init(%s) failed: %d\n", argv[1], ret);
        return 1;
    }

    memset(&version, 0, sizeof(version));
    ret = rknn_query(context, RKNN_QUERY_SDK_VERSION, &version, sizeof(version));
    if (ret != RKNN_SUCC) {
        fprintf(stderr, "rknn_query(RKNN_QUERY_SDK_VERSION) failed: %d\n", ret);
        rknn_destroy(context);
        return 1;
    }

    printf("RKNN API version: %s\n", version.api_version);
    printf("RKNN driver version: %s\n", version.drv_version);

    ret = rknn_destroy(context);
    if (ret != RKNN_SUCC) {
        fprintf(stderr, "rknn_destroy failed: %d\n", ret);
        return 1;
    }

    return 0;
}
