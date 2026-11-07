/*
 * fotomosaico_neon.c - Implementacion nueva optimizada para Raspberry Pi 5.
 *
 * Compilar:
 *   -DUSE_NEON=1 para ARM NEON (AArch64)
 *
 * Interfaz compatible con el programa de referencia:
 *   entrada.jpg catalogo/ salida.jpg celda tile
 *
 * Los tiempos y el hash se imprimen en una linea METRICS para que
 * benchmark.py pueda generar el CSV automaticamente.
 */
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#include <arm_neon.h>
#include <dirent.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>

typedef struct {
    unsigned char *pixels;
    int width, height;
    unsigned char r, g, b;
} Tile;

typedef struct { unsigned char r, g, b; } RGB;

static Tile *tiles;
static int tile_count;
static int16_t *catalog_r, *catalog_g, *catalog_b;

static double clock_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

/* Igual que el original: vecino mas cercano, dimensiones exactas. */
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

/*
 * INTRINSIC NEON: vld3q_u8 procesa 16 pixeles RGB por iteracion.
 * vaddlvq_u8 hace la suma horizontal de cada canal en una instruccion
 * de reduccion. El sobrante se resuelve escalarmente sin leer fuera.
 * Antes: 3 sumas escalares por pixel.
 * Ahora: 16 pixeles por bloque vectorial.
 */
static RGB average_color(const unsigned char *p, size_t n) {
    uint64_t r = 0, g = 0, b = 0;
    size_t i = 0;
    for (; i + 16 <= n; i += 16) {
        uint8x16x3_t v = vld3q_u8(p + i * 3);
        r += vaddlvq_u8(v.val[0]);
        g += vaddlvq_u8(v.val[1]);
        b += vaddlvq_u8(v.val[2]);
    }
    for (; i < n; ++i) {
        r += p[3*i]; g += p[3*i+1]; b += p[3*i+2];
    }
    return (RGB){(unsigned char)(r/n), (unsigned char)(g/n),
                 (unsigned char)(b/n)};
}

static int is_image(const char *s) {
    const char *e = strrchr(s, '.');
    return e && (!strcasecmp(e, ".jpg") || !strcasecmp(e, ".jpeg") ||
                 !strcasecmp(e, ".png"));
}

static int add_tile(const char *path, int size) {
    int w, h, ch;
    unsigned char *im = stbi_load(path, &w, &h, &ch, 3);
    if (!im) return 0;
    unsigned char *small = resize_image(im, w, h, size, size);
    stbi_image_free(im);
    if (!small) return 0;

    Tile *tmp = realloc(tiles, (size_t)(tile_count + 1) * sizeof(*tiles));
    if (!tmp) { free(small); return 0; }
    tiles = tmp;
    RGB c = average_color(small, (size_t)size * size);
    tiles[tile_count++] = (Tile){small, size, size, c.r, c.g, c.b};
    return 1;
}

/* Se conserva el orden de readdir del programa original para no alterar
 * el desempate si dos fotos del catalogo tienen exactamente la misma distancia. */
static int load_catalog(const char *folder, int tile_size) {
    DIR *d = opendir(folder);
    if (!d) { perror("No se pudo abrir catalogo"); return 0; }
    struct dirent *e;
    char path[4096];
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.' || !is_image(e->d_name)) continue;
        int n = snprintf(path, sizeof(path), "%s/%s", folder, e->d_name);
        if (n > 0 && (size_t)n < sizeof(path)) add_tile(path, tile_size);
    }
    closedir(d);
    if (!tile_count) return 0;

    catalog_r = malloc((size_t)tile_count * sizeof(*catalog_r));
    catalog_g = malloc((size_t)tile_count * sizeof(*catalog_g));
    catalog_b = malloc((size_t)tile_count * sizeof(*catalog_b));
    if (!catalog_r || !catalog_g || !catalog_b) return 0;
    for (int i = 0; i < tile_count; ++i) {
        catalog_r[i] = tiles[i].r;
        catalog_g[i] = tiles[i].g;
        catalog_b[i] = tiles[i].b;
    }
    return tile_count;
}

/*
 * INTRINSIC NEON: cuatro candidatos de catalogo en paralelo.
 * vld1_s16 carga 4 componentes; vmovl_s16 amplia a int32;
 * vmulq_s32 y vaddq_s32 calculan las distancias RGB cuadraticas.
 * Antes: una distancia completa por iteracion escalar.
 * Ahora: cuatro distancias por iteracion vectorial.
 * La seleccion lane a lane mantiene el mismo desempate (<) del original.
 */
static int find_best_tile(RGB c) {
    int best = 0, i = 0;
    uint32_t best_d = UINT32_MAX;
    int32x4_t cr = vdupq_n_s32(c.r), cg = vdupq_n_s32(c.g),
              cb = vdupq_n_s32(c.b);
    for (; i + 4 <= tile_count; i += 4) {
        int32x4_t dr = vsubq_s32(cr, vmovl_s16(vld1_s16(catalog_r+i)));
        int32x4_t dg = vsubq_s32(cg, vmovl_s16(vld1_s16(catalog_g+i)));
        int32x4_t db = vsubq_s32(cb, vmovl_s16(vld1_s16(catalog_b+i)));
        int32x4_t vd = vaddq_s32(vaddq_s32(vmulq_s32(dr,dr),
                                           vmulq_s32(dg,dg)),
                                           vmulq_s32(db,db));
        uint32_t d[4];
        vst1q_u32(d, vreinterpretq_u32_s32(vd));
        for (int k = 0; k < 4; ++k)
            if (d[k] < best_d) { best_d = d[k]; best = i+k; }
    }
    for (; i < tile_count; ++i) {
        int dr = (int)c.r-catalog_r[i], dg = (int)c.g-catalog_g[i],
            db = (int)c.b-catalog_b[i];
        uint32_t d = (uint32_t)(dr*dr + dg*dg + db*db);
        if (d < best_d) { best_d = d; best = i; }
    }
    return best;
}

/*
 * INTRINSIC NEON para promediar cada fila de la celda: bloques de 16
 * pixeles RGB. Se conserva el tratamiento de bordes parciales.
 * Antes: bucle anidado y acumulacion por pixel.
 * Ahora: sumas vectoriales por bloques de 16.
 */
static RGB cell_average(const unsigned char *img, int w,
                        int x0, int y0, int x1, int y1) {
    uint64_t r=0, g=0, b=0;
    uint64_t n=(uint64_t)(x1-x0)*(uint64_t)(y1-y0);
    for (int y=y0; y<y1; ++y) {
        const unsigned char *row = img + ((size_t)y*w+x0)*3;
        int x=0, width=x1-x0;
        for (; x+16<=width; x+=16) {
            uint8x16x3_t v=vld3q_u8(row+(size_t)x*3);
            r+=vaddlvq_u8(v.val[0]);
            g+=vaddlvq_u8(v.val[1]);
            b+=vaddlvq_u8(v.val[2]);
        }
        for (; x<width; ++x) {
            r+=row[3*x]; g+=row[3*x+1]; b+=row[3*x+2];
        }
    }
    return n ? (RGB){(unsigned char)(r/n),(unsigned char)(g/n),
                     (unsigned char)(b/n)} : (RGB){0,0,0};
}

static void paste_tile(unsigned char *out, int out_w, const Tile *t,
                       int x0, int y0) {
    size_t bytes=(size_t)t->width*3;
    for (int y=0; y<t->height; ++y)
        memcpy(out+((size_t)(y0+y)*out_w+x0)*3,
               t->pixels+(size_t)y*bytes, bytes);
}

/* Hash FNV-1a sobre RGB final, independiente del contenedor JPEG. */
static uint64_t hash_pixels(const unsigned char *p, size_t n) {
    uint64_t h=UINT64_C(14695981039346656037);
    for (size_t i=0; i<n; ++i) { h^=p[i]; h*=UINT64_C(1099511628211); }
    return h;
}

int main(int argc, char **argv) {
    if (argc != 6) {
        fprintf(stderr, "Uso: %s entrada.jpg catalogo salida.jpg celda tile\n", argv[0]);
        return 2;
    }
    int cell=atoi(argv[4]), ts=atoi(argv[5]);
    if (cell<=0 || ts<=0) { fprintf(stderr,"celda/tile invalidos\n"); return 2; }

    double t0=clock_s();
    int w,h,ch;
    unsigned char *src=stbi_load(argv[1],&w,&h,&ch,3);
    if (!src) { fprintf(stderr,"No se pudo leer entrada: %s\n",argv[1]); return 1; }
    double t1=clock_s();

    int loaded=load_catalog(argv[2],ts);
    double t2=clock_s();
    if (!loaded) { fprintf(stderr,"Catalogo vacio o sin memoria\n"); stbi_image_free(src); return 1; }

    int cols=(w+cell-1)/cell, rows=(h+cell-1)/cell;
    int ow=cols*ts, oh=rows*ts;
    unsigned char *out=malloc((size_t)ow*oh*3);
    if (!out) { fprintf(stderr,"Sin memoria para salida\n"); return 1; }

    for (int cy=0; cy<rows; ++cy) for (int cx=0; cx<cols; ++cx) {
        int x0=cx*cell, y0=cy*cell;
        int x1=x0+cell, y1=y0+cell;
        if (x1>w) x1=w; if (y1>h) y1=h;
        RGB c=cell_average(src,w,x0,y0,x1,y1);
        int best=find_best_tile(c);
        paste_tile(out,ow,&tiles[best],cx*ts,cy*ts);
    }
    double t3=clock_s();
    uint64_t hash=hash_pixels(out,(size_t)ow*oh*3);
    int ok=stbi_write_jpg(argv[3],ow,oh,3,out,95);
    double t4=clock_s();

    printf("METRICS,%d,%d,%d,%.9f,%.9f,%.9f,%.9f,%llu,%d,%d\n",
           tile_count,cols,rows,t1-t0,t2-t1,t3-t2,t4-t0,
           (unsigned long long)hash,ow,oh);
    fprintf(stderr,"Fotomosaico %s: %s (%d x %d), catalogo=%d\n",
            ok?"generado":"fallo",argv[3],ow,oh,tile_count);

    for (int i=0;i<tile_count;++i) free(tiles[i].pixels);
    free(tiles); free(catalog_r); free(catalog_g); free(catalog_b);
    free(out); stbi_image_free(src);
    return ok?0:1;
}
