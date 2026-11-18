# Proyecto 2 — mediciones de puntos 3 y 4

Esta version reorganiza el proyecto para que las mediciones se puedan repetir en la Raspberry Pi 5 y queden guardadas automaticamente en CSV.

## 1. Preparacion en la Raspberry Pi 5

Desde `fotomosaico/`:

```bash
chmod +x medir_p3_p4.sh
make clean
make build
```

Descargar el catalogo `val2017` indicado por el enunciado y dejarlo, por ejemplo, como:

```text
fotomosaico/../val2017/
```

Las dos imagenes de prueba ya estan incluidas en `imagenes_prueba/`.

## 2. Ejecutar todas las mediciones

La corrida recomendada es:

```bash
make mediciones REPS=5 CATALOG=../val2017 CPU=2
```

Esto ejecuta:

- version escalar: O0, O2, O3;
- NEON nivel 1: O0, O2, O3;
- NEON nivel 2: O0, O2, O3;
- NEON nivel 3: O0, O2, O3;
- las dos imagenes;
- cinco corridas por configuracion;
- `time` para tiempo externo;
- `perf stat` cuando esta disponible;
- temperatura y frecuencia antes de cada corrida;
- hash de la imagen final para verificar que las salidas sean consistentes.

## 3. Iteraciones de optimizacion NEON

El archivo `fotomosaico_neon.c` usa `NEON_LEVEL`:

1. `NEON_LEVEL=1`: vectoriza `average_color()` del catalogo.
2. `NEON_LEVEL=2`: agrega la vectorizacion de `find_best_tile()` procesando cuatro candidatos por iteracion.
3. `NEON_LEVEL=3`: agrega la vectorizacion de `cell_average()` procesando bloques de 16 pixeles RGB.

Los tres niveles se ejecutan con O0, O2 y O3. Esto permite medir el efecto incremental de cada optimizacion sin tener que mantener tres archivos fuente diferentes.

## 4. Archivos generados

En:

```text
resultados/resultados exp3_4/
```

se generan:

- `medicion_1optimizacion.csv`
- `medicion_2optimizacion.csv`
- `medicion_3optimizacion.csv`
- `mediciones_escalar.csv`
- `tabla_mediana_tiempos.csv`
- `tabla_punto4.csv`
- `speedup_punto4.csv`
- `resumen_punto3.csv`
- `medianas_perf_neon_O2.csv`
- `registro_optimizaciones.csv`

Los tres archivos `medicion_#optimizacion.csv` contienen las corridas completas de ese nivel de NEON. Cada archivo contiene 2 imagenes x 3 opciones de compilacion x REPS corridas.

## 5. Punto 4

La comparacion principal del enunciado usa O2. `speedup_punto4.csv` calcula:

```text
speedup = T_escalar_O2 / T_NEON_O2
reduccion(%) = (T_escalar_O2 - T_NEON_O2) / T_escalar_O2 * 100
```

`tabla_punto4.csv` contiene los tiempos medianos para las seis configuraciones solicitadas.

## 6. Perfilado

Para generar perfiles de la version final NEON O2:

```bash
make perfil REPS=5 CATALOG=../val2017 CPU=2
```

Se guardan los `.data`, reportes de `perf report` y las salidas auxiliares en:

```text
resultados/resultados exp3_4/perfil/
```

Si `perf` no tiene permisos, las mediciones de tiempo continuan y las columnas `perf_*` quedan como `NA`.

## 7. Tiempo de implementacion

`registro_optimizaciones.csv` deja las columnas de tiempo de implementacion y evaluacion para completar manualmente. Esos tiempos no deben inventarse a partir del tiempo de ejecucion del programa: corresponden al tiempo real invertido por el grupo durante el desarrollo.

## 8. Redireccion manual

El ejecutable tambien imprime una sola fila CSV por ejecucion. Por ejemplo:

```bash
BUILD_OPT=O2 IMAGE_ID=prueba1 \
./bin/fotomosaico_neon_N3_O2 \
../imagenes_prueba/prueba1.jpg ../val2017 salida.jpg 10 20 \
> medicion_manual.csv
```

El `Makefile` y `medir_p3_p4.sh` ya realizan automaticamente la captura completa y agregan los contadores de `perf`.
