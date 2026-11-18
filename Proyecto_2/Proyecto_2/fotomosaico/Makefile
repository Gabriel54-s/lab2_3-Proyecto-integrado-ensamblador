# Makefile - Proyecto 2: fotomosaicos + ARM NEON
#
# Ejecutar EN LA RASPBERRY PI 5 (o en un entorno AArch64 con NEON).
#
# Comandos principales:
#   make build
#   make mediciones REPS=5
#   make punto3
#   make punto4
#   make perfil
#   make todo
#
# Variables utiles:
#   CATALOG=../val2017
#   REPS=5
#   CELL=10 TILE=20
#   CPU=2              # usar -1 para no fijar CPU
#   USE_PERF=auto      # auto, 0 o 1
#
# Para compilacion cruzada:
#   make build CC=aarch64-linux-gnu-gcc
#   Las mediciones/perf deben ejecutarse en la Raspberry Pi.

CC ?= gcc

CFLAGS_COMMON = -std=gnu11 -Wall -Wextra -Wpedantic -g -march=armv8-a
SRC_DIR = codigo
BIN_DIR = bin

SCALAR_SRC = $(SRC_DIR)/fotomosaico.c
NEON_SRC = $(SRC_DIR)/fotomosaico_neon.c

REPS ?= 5
CELL ?= 10
TILE ?= 20
CPU ?= 2
CATALOG ?= ../val2017
IMAGES ?= ../imagenes_prueba/prueba1.jpg ../imagenes_prueba/prueba2.jpg
USE_PERF ?= auto

RESULTS_DIR = resultados/resultados exp3_4

.DEFAULT_GOAL := all

.PHONY: all help build build-scalar build-neon mediciones punto3 punto4 perfil todo clean

all: build

help:
	@echo ""
	@echo "Proyecto 2 - medicion de optimizacion NEON"
	@echo ""
	@echo "  make build       Compila escalar O0/O2/O3 y NEON niveles 1/2/3 O0/O2/O3"
	@echo "  make mediciones   Ejecuta todas las corridas (>=5 por configuracion)"
	@echo "  make punto3       Alias de mediciones"
	@echo "  make punto4       Alias de mediciones"
	@echo "  make perfil       perf record/report sobre NEON nivel 3 -O2"
	@echo "  make todo         build + mediciones + perfil"
	@echo "  make clean        Elimina binarios y resultados generados"
	@echo ""
	@echo "Ejemplo:"
	@echo "  make todo REPS=5 CATALOG=../val2017 CPU=2"
	@echo "  make mediciones USE_PERF=0"
	@echo ""

build: build-scalar build-neon

build-scalar:
	@mkdir -p $(BIN_DIR)
	@echo "== Compilando version escalar =="
	$(CC) $(CFLAGS_COMMON) -O0 $(SCALAR_SRC) -o $(BIN_DIR)/fotomosaico_escalar_O0 -lm
	$(CC) $(CFLAGS_COMMON) -O2 $(SCALAR_SRC) -o $(BIN_DIR)/fotomosaico_escalar_O2 -lm
	$(CC) $(CFLAGS_COMMON) -O3 $(SCALAR_SRC) -o $(BIN_DIR)/fotomosaico_escalar_O3 -lm

build-neon:
	@mkdir -p $(BIN_DIR)
	@echo "== Compilando niveles incrementales NEON =="
	@for level in 1 2 3; do \
		for opt in O0 O2 O3; do \
			echo "  NEON nivel $$level -$$opt"; \
			$(CC) $(CFLAGS_COMMON) -DNEON_LEVEL=$$level -$$opt \
				$(NEON_SRC) -o $(BIN_DIR)/fotomosaico_neon_N$${level}_$$opt -lm || exit 1; \
		done; \
	done

mediciones: build
	@echo "== Ejecutando mediciones de puntos 3 y 4 =="
	@REPS=$(REPS) CELL=$(CELL) TILE=$(TILE) CPU=$(CPU) \
		CATALOG="$(CATALOG)" IMAGES="$(IMAGES)" \
		RESULTS_DIR="$(RESULTS_DIR)" BIN_DIR="$(BIN_DIR)" \
		USE_PERF=$(USE_PERF) CC="$(CC)" \
		./medir_p3_p4.sh

punto3: mediciones

punto4: mediciones

perfil: build
	@mkdir -p "$(RESULTS_DIR)/perfil"
	@echo "== Perfilando NEON nivel 3 -O2 =="
	@if ! command -v perf >/dev/null 2>&1; then \
		echo "AVISO: perf no esta instalado; se omite perfil."; \
		exit 0; \
	fi
	@if ! perf stat -x, -e cycles true >/dev/null 2>&1; then \
		echo "AVISO: perf no tiene permisos/eventos disponibles; se omite perfil."; \
		exit 0; \
	fi
	@runner=""; \
	if [ "$(CPU)" != "-1" ] && command -v taskset >/dev/null 2>&1 && taskset -c "$(CPU)" true >/dev/null 2>&1; then \
		runner="taskset -c $(CPU)"; \
	fi; \
	for img in $(IMAGES); do \
		id=$$(basename "$$img"); id=$${id%.*}; \
		echo "  perf record $$id"; \
		perf record -g -o "$(RESULTS_DIR)/perfil/$${id}_neon_O2.data" -- \
			env BUILD_OPT=O2 IMAGE_ID="$$id" $$runner \
			"$(BIN_DIR)/fotomosaico_neon_N3_O2" "$$img" "$(CATALOG)" \
			"$(RESULTS_DIR)/perfil/$${id}_neon_O2.jpg" "$(CELL)" "$(TILE)" \
			>"$(RESULTS_DIR)/perfil/$${id}_program.csv" 2>"$(RESULTS_DIR)/perfil/$${id}_perf.err" || true; \
		perf report -i "$(RESULTS_DIR)/perfil/$${id}_neon_O2.data" --stdio \
			--no-children --sort symbol \
			>"$(RESULTS_DIR)/perfil/$${id}_report.txt" 2>/dev/null || true; \
	done
	@echo "Perfiles guardados en $(RESULTS_DIR)/perfil"

todo: build mediciones perfil

clean:
	rm -rf "$(BIN_DIR)" "$(RESULTS_DIR)"
