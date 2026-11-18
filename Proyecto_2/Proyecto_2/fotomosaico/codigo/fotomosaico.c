#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#include <dirent.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <sys/resource.h>

typedef struct {
    unsigned char *pixels;
    int width, height;
    unsigned char r, g, b;
} Tile;

typedef struct { unsigned char r, g, b; } RGB;

static Tile *tiles = NULL;
static int tile_count = 0;

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static double cpu_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static unsigned char *resize_image(const unsigned char *src,
                                   int sw, int sh, int dw, int dh) {
    unsigned char *dst = malloc((size_t)dw * dh * 3);
    if (!dst) return NULL;
    for (int y = 0; y < dh; ++y) {
        int sy = (int)((int64_t)y * sh / dh);
        for (int x = 0; x < dw; ++x) {
            int sx = (int)((int64_t)x * sw / dw);
            const unsigned char *p = src + ((size_t)sy * sw + sx) * 3;
            unsigned char *q = dst + ((size_t)y * dw + x) * 3;
            q[0] = p[0]; q[1] = p[1]; q[2] = p[2];
        }
    }
    return dst;
}

static RGB average_color(const unsigned char *img, size_t n) {
    uint64_t r = 0, g = 0, b = 0;
    for (size_t i = 0; i < n; ++i) {
        r += img[3*i]; g += img[3*i+1]; b += img[3*i+2];
    }
    return (RGB){(unsigned char)(r/n), (unsigned char)(g/n),
                 (unsigned char)(b/n)};
}

static int is_image(const char *name) {
    const char *ext = strrchr(name, '.');
    return ext && (!strcasecmp(ext, ".jpg") || !strcasecmp(ext, ".jpeg") ||
                   !strcasecmp(ext, ".png"));
}

static int add_tile(const char *path, int size) {
    int w, h, ch;
    unsigned char *img = stbi_load(path, &w, &h, &ch, 3);
    if (!img) return 0;

    unsigned char *small = resize_image(img, w, h, size, size);
    stbi_image_free(img);
    if (!small) return 0;

    Tile *tmp = realloc(tiles, (size_t)(tile_count + 1) * sizeof(*tiles));
    if (!tmp) { free(small); return 0; }
    tiles = tmp;

    RGB c = average_color(small, (size_t)size * size);
    tiles[tile_count++] = (Tile){small, size, size, c.r, c.g, c.b};
    return 1;
}

static int load_catalog(const char *folder, int tile_size) {
    DIR *dir = opendir(folder);
    if (!dir) { perror("No se pudo abrir el catalogo"); return 0; }

    struct dirent *entry;
    char path[4096];

    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.' || !is_image(entry->d_name)) continue;
        int n = snprintf(path, sizeof(path), "%s/%s", folder, entry->d_name);
        if (n > 0 && (size_t)n < sizeof(path)) add_tile(path, tile_size);
    }

    closedir(dir);
    return tile_count;
}

static int find_best_tile(RGB target) {
    int best = 0;
    uint32_t best_dist = UINT32_MAX;

    for (int i = 0; i < tile_count; ++i) {
        int dr = (int)target.r - tiles[i].r;
        int dg = (int)target.g - tiles[i].g;
        int db = (int)target.b - tiles[i].b;
        uint32_t d = (uint32_t)(dr*dr + dg*dg + db*db);
        if (d < best_dist) { best_dist = d; best = i; }
    }
    return best;
}

static RGB cell_average(const unsigned char *img, int w,
                        int x0, int y0, int x1, int y1) {
    uint64_t r = 0, g = 0, b = 0, n = 0;
    for (int y = y0; y < y1; ++y) {
        for (int x = x0; x < x1; ++x) {
            const unsigned char *p = img + ((size_t)y*w + x)*3;
            r += p[0]; g += p[1]; b += p[2]; ++n;
        }
    }
    return n ? (RGB){(unsigned char)(r/n),(unsigned char)(g/n),
                     (unsigned char)(b/n)} : (RGB){0,0,0};
}

static void paste_tile(unsigned char *out, int out_w, const Tile *t,
                       int x0, int y0) {
    size_t bytes = (size_t)t->width * 3;
    for (int y = 0; y < t->height; ++y)
        memcpy(out + ((size_t)(y0+y)*out_w+x0)*3,
               t->pixels + (size_t)y*bytes, bytes);
}

static uint64_t hash_pixels(const unsigned char *p, size_t n) {
    uint64_t h = UINT64_C(14695981039346656037);
    for (size_t i = 0; i < n; ++i) { h ^= p[i]; h *= UINT64_C(1099511628211); }
    return h;
}

int main(int argc, char **argv) {
    if (argc != 6) {
        fprintf(stderr, "Uso: %s entrada.jpg catalogo salida.jpg celda tile\n", argv[0]);
        return 2;
    }

    int cell = atoi(argv[4]), tile = atoi(argv[5]);
    if (cell <= 0 || tile <= 0) return 2;

    double t0 = now_s(), c0 = cpu_s();
    int w, h, ch;

    double a = now_s();
    unsigned char *src = stbi_load(argv[1], &w, &h, &ch, 3);
    double t_load = now_s() - a;
    if (!src) { fprintf(stderr, "No se pudo leer la entrada\n"); return 1; }

    a = now_s();
    int loaded = load_catalog(argv[2], tile);
    double t_catalog = now_s() - a;
    if (!loaded) { stbi_image_free(src); return 1; }

    int cols = (w + cell - 1)/cell, rows = (h + cell - 1)/cell;
    int ow = cols*tile, oh = rows*tile;
    unsigned char *out = malloc((size_t)ow*oh*3);
    if (!out) { stbi_image_free(src); return 1; }

    a = now_s();
    for (int cy = 0; cy < rows; ++cy) {
        for (int cx = 0; cx < cols; ++cx) {
            int x0 = cx*cell, y0 = cy*cell;
            int x1 = x0 + cell, y1 = y0 + cell;
            if (x1 > w) x1 = w;
            if (y1 > h) y1 = h;
            RGB c = cell_average(src, w, x0, y0, x1, y1);
            int best = find_best_tile(c);
            paste_tile(out, ow, &tiles[best], cx*tile, cy*tile);
        }
    }
    double t_mosaic = now_s() - a;

    uint64_t hash = hash_pixels(out, (size_t)ow*oh*3);
    a = now_s();
    int ok = stbi_write_jpg(argv[3], ow, oh, 3, out, 95);
    double t_write = now_s() - a;

    double t_total = now_s() - t0;
    double c_total = cpu_s() - c0;
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);

    const char *opt=getenv("BUILD_OPT"); if (!opt) opt="NA";
    const char *img=getenv("IMAGE_ID"); if (!img) img="NA";

    printf("scalar,%s,%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%ld,%llu,%d,%d\n",
           opt, img, w, h, cell, tile, tile_count, cols, rows,
           cols*rows, cols*rows*tile_count, ok ? 0 : 1,
           t_load, t_catalog, t_mosaic, t_write, t_total, c_total,
           ru.ru_maxrss, (unsigned long long)hash, ow, oh);

    for (int i = 0; i < tile_count; ++i) free(tiles[i].pixels);
    free(tiles); free(out); stbi_image_free(src);
    return ok ? 0 : 1;
}
