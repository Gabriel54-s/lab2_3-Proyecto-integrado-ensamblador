CC = gcc

CFLAGS = -Wall -Wextra
DEBUG = -g
ARCH = -march=armv8-a

N = 5

EXEC = convertir_espacio_color
CSV = tiempo.csv


.PHONY: help \
        buildNormal \
        buildNormalO1 \
        buildNormalO2 \
        buildNormalO3 \
        buildNEON \
        buildNEONO1 \
        buildNEONO2 \
        buildNEONO3 \
        bucle \
        clean


# ---------------------------------------------------------
# Help
# ---------------------------------------------------------

help:
	@echo "Available targets:"
	@echo ""
	@echo "  buildNormal       Compile normal version without optimization"
	@echo "  buildNormalO1     Compile normal version with -O1"
	@echo "  buildNormalO2     Compile normal version with -O2"
	@echo "  buildNormalO3     Compile normal version with -O3"
	@echo ""
	@echo "  buildNEON         Compile NEON version without optimization"
	@echo "  buildNEONO1       Compile NEON version with -O1"
	@echo "  buildNEONO2       Compile NEON version with -O2"
	@echo "  buildNEONO3       Compile NEON version with -O3"
	@echo ""
	@echo "  bucle             Run executable N times"
	@echo "  clean             Remove generated files"
	@echo ""
	@echo "Examples:"
	@echo "  make buildNormal"
	@echo "  make buildNormalO3"
	@echo "  make buildNEON"
	@echo "  make buildNEONO3"
	@echo "  make bucle N=100"
	@echo "  make clean"


# ---------------------------------------------------------
# Normal version
# ---------------------------------------------------------

buildNormal:
	$(CC) $(CFLAGS) $(DEBUG) conversion_espacio_color.c -o $(EXEC) -lm


# ---------------------------------------------------------
# Normal version with optimization
# ---------------------------------------------------------

buildNormalO1:
	$(CC) $(CFLAGS) $(DEBUG) -O1 conversion_espacio_color.c -o $(EXEC) -lm

buildNormalO2:
	$(CC) $(CFLAGS) $(DEBUG) -O2 conversion_espacio_color.c -o $(EXEC) -lm

buildNormalO3:
	$(CC) $(CFLAGS) $(DEBUG) -O3 conversion_espacio_color.c -o $(EXEC) -lm


# ---------------------------------------------------------
# NEON version without optimization
# ---------------------------------------------------------

buildNEON:
	$(CC) $(CFLAGS) $(DEBUG) $(ARCH) conversion_espacio_color_neon.c -o $(EXEC) -lm


# ---------------------------------------------------------
# NEON version with optimization
# ---------------------------------------------------------

buildNEONO1:
	$(CC) $(CFLAGS) $(DEBUG) -O1 $(ARCH) conversion_espacio_color_neon.c -o $(EXEC) -lm

buildNEONO2:
	$(CC) $(CFLAGS) $(DEBUG) -O2 $(ARCH) conversion_espacio_color_neon.c -o $(EXEC) -lm

buildNEONO3:
	$(CC) $(CFLAGS) $(DEBUG) -O3 $(ARCH) conversion_espacio_color_neon.c -o $(EXEC) -lm


# ---------------------------------------------------------
# Run executable N times
# ---------------------------------------------------------

bucle:
	i=1; while [ $$i -le $(N) ]; do \
		./$(EXEC); \
		i=$$((i + 1)); \
	done > $(CSV)


# ---------------------------------------------------------
# Clean
# ---------------------------------------------------------

clean:
	rm -f $(EXEC) $(CSV)