#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#define NUM_CHANNELS 3

#include <stdio.h>
#include <stdlib.h>
#include <time.h>
int main() {
    clock_t inicio,fin;
    //cargado de la imagen
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

    // Imagen en escala de grises: 1 byte por píxel
    unsigned char *gris = malloc(ancho * alto);

    if (gris == NULL) {
        printf("Error reservando memoria.\n");
        stbi_image_free(rgb);
        return 1;
    }
    // perfilacion 
    fin = clock();
    double tiempo = (double) (fin-inicio)/CLOCKS_PER_SEC;
    //printf("tamaño %dx%d\n",ancho,alto);
    //printf("tiempo de carga, tiempo de conversion, tiempo de guardado\n");
    printf("%.6f,",tiempo);
    //conversion a gris
   
    inicio = clock();
    // Conversión RGB -> escala de grises
    for (int y = 0; y < alto; y++) {
        for (int x = 0; x < ancho; x++) {

            int i = (y * ancho + x) * NUM_CHANNELS;

            unsigned char R = rgb[i];
            unsigned char G = rgb[i + 1];
            unsigned char B = rgb[i + 2];

            // Fórmula de luminancia
            gris[y * ancho + x] =
                0.299 * R +
                0.587 * G +
                0.114 * B;
        }
    }
    fin = clock();
    tiempo = (double)(fin - inicio)/ CLOCKS_PER_SEC;
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
