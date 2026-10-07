#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <arm_neon.h>

#define NUM_CHANNELS 3

void convertir_gris_neon(
    const unsigned char *rgb,
    unsigned char *gris,
    int ancho,
    int alto
) {
    int total = ancho * alto;
    int i = 0;

    // Procesar 8 píxeles por iteración
    for (; i <= total - 8; i += 8) {

        // Cargar 8 píxeles RGB intercalados
        uint8x8x3_t pixels = vld3_u8(&rgb[i * 3]);

        // Convertir uint8 -> uint16
        uint16x8_t r = vmovl_u8(pixels.val[0]);
        uint16x8_t g = vmovl_u8(pixels.val[1]);
        uint16x8_t b = vmovl_u8(pixels.val[2]);

        // Aproximación:
        //
        // gris = (77*R + 150*G + 29*B) / 256
        //
        // 77/256  ≈ 0.3008
        // 150/256 ≈ 0.5859
        // 29/256  ≈ 0.1133

        uint16x8_t resultado = vmulq_n_u16(r, 77);
        resultado = vmlaq_n_u16(resultado, g, 150);
        resultado = vmlaq_n_u16(resultado, b, 29);

        // División entre 256
        uint8x8_t gris_vec = vshrn_n_u16(resultado, 8);

        // Guardar 8 píxeles
        vst1_u8(&gris[i], gris_vec);
    }

    // Procesar los píxeles restantes
    for (; i < total; i++) {

        int j = i * 3;

        unsigned char R = rgb[j];
        unsigned char G = rgb[j + 1];
        unsigned char B = rgb[j + 2];

        gris[i] =
            (77 * R + 150 * G + 29 * B) >> 8;
    }
}

int main() {

    // cargado de imagen
    clock_t inicio,fin;
    inicio = clock();
    int ancho, alto, canales;

    // Forzar la lectura a 3 canales: RGB
    unsigned char *rgb = stbi_load(
        "imagen1.jpg",
        &ancho,
        &alto,
        &canales,
        NUM_CHANNELS
    );

    if (rgb == NULL) {
        printf("Error al cargar la imagen.\n");
        return 1;
    }
    fin = clock();
    double tiempo = (double) (fin-inicio)/CLOCKS_PER_SEC;
    printf("%.6f,",tiempo);


    // Imagen en escala de grises: 1 byte por píxel
    unsigned char *gris = malloc(ancho * alto);

    if (gris == NULL) {
        printf("Error reservando memoria.\n");
        stbi_image_free(rgb);
        return 1;
    }

    inicio = clock();

    // Conversión RGB -> escala de grises
    convertir_gris_neon(rgb, gris, ancho, alto);
    
    fin = clock();

    tiempo = (double)(fin - inicio) / CLOCKS_PER_SEC;
    printf("%.6f,",tiempo);

    // Guardar resultado como PNG
    inicio = clock();
    stbi_write_png(
        "imagen_gris.png",
        ancho,
        alto,
        1,
        gris,
        ancho
    );

    free(gris);
    stbi_image_free(rgb);

    //printf("Imagen convertida correctamente.\n");
    fin = clock();
    tiempo = (double) (fin-inicio)/CLOCKS_PER_SEC;
    printf("%.6f\n",tiempo);
    return 0;
}
