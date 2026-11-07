
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

typedef struct {
    unsigned char *pixels;
    int width;
    int height;
    double r, g, b;
} Tile;

typedef struct {
    unsigned char r, g, b;
} RGB;

static Tile *tiles = NULL;
static int tile_count = 0;

/* Redimensionamiento por vecino mas cercano */
static unsigned char *resize_image(
    const unsigned char *src,
    int sw, int sh, int dw, int dh)
{
    unsigned char *dst = malloc((size_t)dw * dh * 3);
    if (!dst) return NULL;

    for (int y = 0; y < dh; y++) {
        int sy = (int)((long long)y * sh / dh);

        for (int x = 0; x < dw; x++) {
            int sx = (int)((long long)x * sw / dw);

            const unsigned char *p =
                src + ((size_t)sy * sw + sx) * 3;

            unsigned char *q =
                dst + ((size_t)y * dw + x) * 3;

            q[0] = p[0];
            q[1] = p[1];
            q[2] = p[2];
        }
    }

    return dst;
}

/* Color promedio de una imagen RGB */
static RGB average_color(
    const unsigned char *img, int w, int h)
{
    unsigned long long r = 0, g = 0, b = 0;
    size_t n = (size_t)w * h;

    for (size_t i = 0; i < n; i++) {
        r += img[3 * i];
        g += img[3 * i + 1];
        b += img[3 * i + 2];
    }

    RGB c = {
        (unsigned char)(r / n),
        (unsigned char)(g / n),
        (unsigned char)(b / n)
    };

    return c;
}

/* Carga una fotografia y la agrega al catalogo */
static int add_tile(const char *path, int size)
{
    int w, h, channels;

    unsigned char *img =
        stbi_load(path, &w, &h, &channels, 3);

    if (!img) return 0;

    unsigned char *small =
        resize_image(img, w, h, size, size);

    stbi_image_free(img);

    if (!small) return 0;

    Tile *tmp = realloc(
        tiles, (size_t)(tile_count + 1) * sizeof(Tile));

    if (!tmp) {
        free(small);
        return 0;
    }

    tiles = tmp;

    RGB c = average_color(small, size, size);

    tiles[tile_count++] = (Tile) {
        .pixels = small,
        .width = size,
        .height = size,
        .r = c.r,
        .g = c.g,
        .b = c.b
    };

    return 1;
}

static int is_image(const char *name)
{
    const char *ext = strrchr(name, '.');
    if (!ext) return 0;

    return !strcasecmp(ext, ".jpg")  ||
           !strcasecmp(ext, ".jpeg") ||
           !strcasecmp(ext, ".png");
}

/* Lee las imagenes de una carpeta, sin recorrer subcarpetas */
static int load_catalog(const char *folder, int tile_size)
{
    DIR *dir = opendir(folder);

    if (!dir) {
        perror("No se pudo abrir el catalogo");
        return 0;
    }

    struct dirent *entry;
    char path[4096];

    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.' ||
            !is_image(entry->d_name))
            continue;

        int n = snprintf(path, sizeof(path), "%s/%s",
                         folder, entry->d_name);

        if (n < 0 || (size_t)n >= sizeof(path))
            continue;

        add_tile(path, tile_size);
    }

    closedir(dir);
    return tile_count;
}

/* Busca el color promedio mas parecido */
static int find_best_tile(RGB target)
{
    int best = 0;
    unsigned int best_dist = UINT32_MAX;

    for (int i = 0; i < tile_count; i++) {
        int dr = (int)target.r - (int)tiles[i].r;
        int dg = (int)target.g - (int)tiles[i].g;
        int db = (int)target.b - (int)tiles[i].b;

        unsigned int dist =
            (unsigned int)(dr * dr + dg * dg + db * db);

        if (dist < best_dist) {
            best_dist = dist;
            best = i;
        }
    }

    return best;
}

/* Calcula el promedio RGB de una celda de la imagen */
static RGB cell_average(
    const unsigned char *img, int w,
    int x0, int y0, int x1, int y1)
{
    unsigned long long r = 0, g = 0, b = 0;
    unsigned long long n = 0;

    for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
            const unsigned char *p =
                img + ((size_t)y * w + x) * 3;

            r += p[0];
            g += p[1];
            b += p[2];
            n++;
        }
    }

    RGB c = {0, 0, 0};

    if (n) {
        c.r = (unsigned char)(r / n);
        c.g = (unsigned char)(g / n);
        c.b = (unsigned char)(b / n);
    }

    return c;
}

static void paste_tile(
    unsigned char *out, int out_w,
    const Tile *tile, int x0, int y0)
{
    for (int y = 0; y < tile->height; y++) {
        unsigned char *dst =
            out + ((size_t)(y0 + y) * out_w + x0) * 3;

        const unsigned char *src =
            tile->pixels + (size_t)y * tile->width * 3;

        memcpy(dst, src, (size_t)tile->width * 3);
    }
}

int main(int argc, char **argv)
{
    if (argc != 6) {
        fprintf(stderr,
            "Uso: %s entrada.jpg catalogo salida.jpg "
            "celda tile\n", argv[0]);
        return 1;
    }

    int cell = atoi(argv[4]);
    int tile_size = atoi(argv[5]);

    if (cell <= 0 || tile_size <= 0) {
        fprintf(stderr, "Celda y tile deben ser positivos.\n");
        return 1;
    }

    int w, h, channels;

    unsigned char *src =
        stbi_load(argv[1], &w, &h, &channels, 3);

    if (!src) {
        fprintf(stderr, "Error al leer la imagen principal.\n");
        return 1;
    }

    if (!load_catalog(argv[2], tile_size)) {
        fprintf(stderr, "Catalogo vacio o no disponible.\n");
        stbi_image_free(src);
        return 1;
    }

    int cols = (w + cell - 1) / cell;
    int rows = (h + cell - 1) / cell;

    int out_w = cols * tile_size;
    int out_h = rows * tile_size;

    unsigned char *out =
        malloc((size_t)out_w * out_h * 3);

    if (!out) {
        fprintf(stderr, "No hay memoria para la salida.\n");
        stbi_image_free(src);
        return 1;
    }

    printf("Catalogo: %d imagenes\n", tile_count);
    printf("Celdas: %d x %d\n", cols, rows);

    for (int cy = 0; cy < rows; cy++) {
        for (int cx = 0; cx < cols; cx++) {
            int x0 = cx * cell;
            int y0 = cy * cell;
            int x1 = x0 + cell;
            int y1 = y0 + cell;

            if (x1 > w) x1 = w;
            if (y1 > h) y1 = h;

            RGB target = cell_average(
                src, w, x0, y0, x1, y1);

            int best = find_best_tile(target);

            paste_tile(out, out_w, &tiles[best],
                       cx * tile_size, cy * tile_size);
        }
    }

    int ok = stbi_write_jpg(
        argv[3], out_w, out_h, 3, out, 95);

    printf("Fotomosaico %s: %s (%d x %d)\n",
           ok ? "generado" : "fallo",
           argv[3], out_w, out_h);

    for (int i = 0; i < tile_count; i++)
        free(tiles[i].pixels);

    free(tiles);
    free(out);
    stbi_image_free(src);

    return ok ? 0 : 1;
}
