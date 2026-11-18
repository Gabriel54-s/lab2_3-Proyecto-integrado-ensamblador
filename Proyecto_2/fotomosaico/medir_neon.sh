#!/usr/bin/env bash
# medir_neon.sh - Mediciones de fotomosaico_neon.c (Etapa 3, con intrinsecos)
#
# Compila -O0/-O2/-O3, corre REPS veces cada imagen (corridas intercaladas,
# fijadas a un CPU, con calentamiento), lee la linea METRICS que imprime el
# programa y genera CSV con medianas y speedup contra la escalar.
# Requiere solo gcc, bash y awk (funciona con mawk). perf es opcional.
#
# Uso (desde la carpeta donde esta fotomosaico_neon.c):
#   ./medir_neon.sh
#   REPS=5 CATALOGO=../val2017 ESCALAR_CSV=../mediciones.csv ./medir_neon.sh
#
# Variables (todas opcionales):
#   SRC=fotomosaico_neon.c   REPS=5   CELDA=10   TILE=20   CPU=2   WARMUP=1
#   OPTS="O0 O2 O3"          CC=gcc
#   CFLAGS="-std=gnu11 -Wall -g"   (las mismas que la escalar; ver nota abajo)
#   CATALOGO=   carpeta del catalogo (default: la primera que exista de
#               val2017 ../val2017 ../catalogo catalogo)
#   IMAGENES=   (default: prueba1.jpg y prueba2.jpg de ../imagenes_prueba o imagenes_prueba)
#   ESCALAR_CSV= mediciones.csv de la escalar (default: el primero que exista de
#               resultados/mediciones.csv ../mediciones.csv mediciones.csv)
#   ESCALAR_SRC= fotomosaico.c original; si existe, verifica que NEON produzca
#               el mismo JPG que la escalar (default: fotomosaico.c o ../codigo/fotomosaico.c)
#   USAR_PERF=auto|0|1  envolver cada corrida con perf stat (como la escalar)
#   PERFIL=0|1  al final, perf record/report de NEON -O2 por imagen
#   SALIDA_DIR=resultados_neon
#
# Nota: la escalar se compilo con -std=gnu11. Con -std=c11 el codificador JPEG
# de stb redondea distinto (contraccion FMA) y el JPG cambia aunque el mosaico
# sea identico; por eso se usan las mismas banderas que la escalar.
set -uo pipefail

primero() { for f in "$@"; do [ -e "$f" ] && { echo "$f"; return; }; done; echo "$1"; }

SRC=${SRC:-fotomosaico_neon.c}
REPS=${REPS:-5}
CELDA=${CELDA:-10}
TILE=${TILE:-20}
CPU=${CPU:-2}
WARMUP=${WARMUP:-1}
OPTS=${OPTS:-"O0 O2 O3"}
CC=${CC:-gcc}
CFLAGS=${CFLAGS:-"-std=gnu11 -Wall -g"}
CATALOGO=${CATALOGO:-$(primero val2017 ../val2017 ../catalogo catalogo)}
DIR_IMG=$(primero ../imagenes_prueba imagenes_prueba ../../imagenes_prueba)
IMAGENES=${IMAGENES:-"$DIR_IMG/prueba1.jpg $DIR_IMG/prueba2.jpg"}
ESCALAR_CSV=${ESCALAR_CSV:-$(primero resultados/mediciones.csv ../mediciones.csv mediciones.csv)}
ESCALAR_SRC=${ESCALAR_SRC:-$(primero fotomosaico.c ../codigo/fotomosaico.c)}
USAR_PERF=${USAR_PERF:-auto}
PERFIL=${PERFIL:-0}
SALIDA_DIR=${SALIDA_DIR:-resultados_neon}
BIN_DIR=$SALIDA_DIR/bin

CSV=$SALIDA_DIR/mediciones_neon.csv
TABLA=$SALIDA_DIR/tabla_neon.csv
SPEEDUP=$SALIDA_DIR/speedup_neon.csv
VERIF=$SALIDA_DIR/verificacion_neon.csv

die() { echo "ERROR: $*" >&2; exit 1; }

# ------------------------------------------------------------ validaciones
[ -f "$SRC" ] || die "no encuentro $SRC (ejecute desde la carpeta de fotomosaico_neon.c o use SRC=ruta)"
grep -q 'METRICS' "$SRC" || die "$SRC no imprime la linea METRICS (no es la version de la Etapa 3)"
for h in stb_image.h stb_image_write.h; do
    [ -f "$(dirname "$SRC")/$h" ] || die "falta $h junto a $SRC"
done
[ -d "$CATALOGO" ] || die "no existe el catalogo '$CATALOGO' (use CATALOGO=ruta)"
for img in $IMAGENES; do [ -f "$img" ] || die "no existe la imagen $img (use IMAGENES=\"a.jpg b.jpg\")"; done

mkdir -p "$SALIDA_DIR/logs" "$SALIDA_DIR/salidas" "$BIN_DIR"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------------ compilacion
for opt in $OPTS; do
    echo "Compilando $BIN_DIR/fotomosaico_neon_$opt"
    $CC $CFLAGS -"$opt" "$SRC" -o "$BIN_DIR/fotomosaico_neon_$opt" -lm \
        || die "fallo la compilacion con -$opt"
done

# ------------------------------------------------------------ herramientas
PIN=()
if [ "$CPU" != "-1" ] && command -v taskset >/dev/null 2>&1 && taskset -c "$CPU" true 2>/dev/null; then
    PIN=(taskset -c "$CPU")
else
    [ "$CPU" != "-1" ] && echo "AVISO: no se puede fijar al CPU $CPU; se corre sin taskset." >&2
    CPU=-1
fi

# Mismos eventos que se usaron para medir la escalar
EVENTOS="task-clock,context-switches,cpu-migrations,page-faults,cycles,instructions,branches,branch-misses,cache-references,cache-misses,L1-dcache-loads,L1-dcache-load-misses"
PERF_COLS="perf_task_clock_ms,perf_context_switches,perf_cpu_migrations,perf_page_faults,perf_cycles,perf_instructions,perf_branches,perf_branch_misses,perf_cache_references,perf_cache_misses,perf_l1d_loads,perf_l1d_load_misses"
HAY_PERF=0
command -v perf >/dev/null 2>&1 && perf stat -x, -e cycles true >/dev/null 2>&1 && HAY_PERF=1
[ "$USAR_PERF" = auto ] && USAR_PERF=$HAY_PERF
if [ "$USAR_PERF" = 1 ] && [ "$HAY_PERF" = 0 ]; then
    echo "AVISO: perf no disponible o sin permisos; columnas perf_* = NA." >&2
    echo "       (sudo apt install linux-perf; sudo sysctl kernel.perf_event_paranoid=1)" >&2
    USAR_PERF=0
fi

leer_temp() { local f=/sys/class/thermal/thermal_zone0/temp; [ -r "$f" ] && awk '{printf "%.1f",$1/1000}' "$f" || echo NA; }
leer_freq() { local c=$CPU; [ "$c" = -1 ] && c=0; cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq 2>/dev/null || echo NA; }
valor_perf() { awk -F, -v ev="$2" '{e=$3; sub(/:u$/,"",e)} e==ev{v=$1; if(v==""||v~/^</)v="NA"; print v; f=1; exit} END{if(!f)print "NA"}' "$1"; }

{
    echo "fecha=$(date -Iseconds)"
    echo "host=$(hostname)"
    echo "uname=$(uname -a)"
    echo "modelo=$( (tr -d '\0' </proc/device-tree/model) 2>/dev/null || echo NA)"
    echo "cc=$($CC --version | head -1)"
    echo "cflags=$CFLAGS -{$OPTS}"
    echo "governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo NA)"
    echo "reps=$REPS celda=$CELDA tile=$TILE cpu=$CPU warmup=$WARMUP usar_perf=$USAR_PERF"
    echo "catalogo=$CATALOGO ($(ls "$CATALOGO" | wc -l) archivos)"
    echo "imagenes=$IMAGENES"
    echo "escalar_csv=$ESCALAR_CSV"
    echo "temp_inicial_c=$(leer_temp)"
} > "$SALIDA_DIR/metadatos_neon.txt"

# ------------------------------------------------------------ calentamiento
# Lleva el catalogo a la cache de paginas antes de medir
ultimo=$(echo $OPTS | awk '{print $NF}')
for ((w=1; w<=WARMUP; w++)); do
    for img in $IMAGENES; do
        echo "[calentamiento $w] $(basename "$img")"
        "${PIN[@]}" "$BIN_DIR/fotomosaico_neon_$ultimo" "$img" "$CATALOGO" "$TMP/w.jpg" "$CELDA" "$TILE" >/dev/null 2>&1 || true
    done
done

# ------------------------------------------------------------ corridas
total=$(( REPS * $(echo $IMAGENES | wc -w) * $(echo $OPTS | wc -w) ))
n=0; fallos=0
rm -f "$TABLA" "$SPEEDUP" "$VERIF"
echo "impl,opt,imagen_id,corrida,orden,fecha,cpu_fijado,temp_c_antes,freq_khz_antes,celda,tile,exit_code,t_externo_s,tiles_catalogo,cols,filas,t_carga_entrada_s,t_catalogo_s,t_mosaico_s,t_total_s,hash_salida,ancho_salida,alto_salida,$PERF_COLS" > "$CSV"

for ((rep=1; rep<=REPS; rep++)); do
  for img in $IMAGENES; do
    id=$(basename "$img"); id=${id%.*}
    for opt in $OPTS; do
        n=$((n+1))
        out="$SALIDA_DIR/salidas/${id}_neon_${opt}_r${rep}.jpg"
        log="$SALIDA_DIR/logs/${id}_neon_${opt}_r${rep}.log"
        pst="$TMP/perf.txt"; rm -f "$pst"
        temp=$(leer_temp); freq=$(leer_freq)
        printf '[%3d/%3d] corrida=%d %-8s neon -%-3s (%s C) ... ' "$n" "$total" "$rep" "$id" "$opt" "$temp"

        cmd=("${PIN[@]}" "$BIN_DIR/fotomosaico_neon_$opt" "$img" "$CATALOGO" "$out" "$CELDA" "$TILE")
        t0=$(date +%s%N)
        if [ "$USAR_PERF" = 1 ]; then
            perf stat -x, -o "$pst" -e "$EVENTOS" -- "${cmd[@]}" >"$log" 2>"$log.err"
        else
            "${cmd[@]}" >"$log" 2>"$log.err"
        fi
        rc=$?
        t1=$(date +%s%N)
        t_ext=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.6f",(b-a)/1e9}')
        cat "$log.err" >> "$log"; rm -f "$log.err"

        # METRICS,tiles,cols,filas,t_carga,t_catalogo,t_mosaico,t_total,hash,ancho,alto
        m=$(grep -m1 '^METRICS,' "$log" | cut -d, -f2-)
        if [ "$rc" != 0 ] || [ -z "$m" ]; then
            echo "FALLO (rc=$rc, ver $log)"; fallos=$((fallos+1)); continue
        fi

        pv=""
        for ev in ${EVENTOS//,/ }; do
            if [ "$USAR_PERF" = 1 ] && [ -f "$pst" ]; then pv="$pv,$(valor_perf "$pst" "$ev")"; else pv="$pv,NA"; fi
        done
        echo "neon,$opt,$id,$rep,$n,$(date -Iseconds),$CPU,$temp,$freq,$CELDA,$TILE,$rc,$t_ext,$m$pv" >> "$CSV"
        echo "ok  total=$(echo "$m" | cut -d, -f7)s  mosaico=$(echo "$m" | cut -d, -f6)s"
        [ "$rep" -gt 1 ] && rm -f "$out"
    done
  done
done

[ "$(wc -l < "$CSV")" -gt 1 ] || die "ninguna corrida termino bien; revise $SALIDA_DIR/logs"
echo "temp_final_c=$(leer_temp)" >> "$SALIDA_DIR/metadatos_neon.txt"

# ------------------------------------------------------------ medianas
# Mediana por (opt, imagen) de las corridas de IMPL con exit_code 0.
# Sirve para el CSV de NEON y para el mediciones.csv de la escalar.
MEDIANAS='
function med(l,  a,k,i,j,t) { k = split(l, a, " ")
    for (i = 2; i <= k; i++) { t = a[i] + 0; j = i - 1
        while (j > 0 && a[j] + 0 > t) { a[j+1] = a[j]; j-- } a[j+1] = t }
    if (k == 0) return "NA"
    return (k % 2) ? a[(k+1)/2] : (a[k/2] + a[k/2+1]) / 2 }
NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
$c["impl"] != IMPL || $c["exit_code"] != 0 { next }
{ k = $c["opt"] SUBSEP $c["imagen_id"]
  if (!(k in n)) o[++nk] = k
  n[k]++
  tt[k] = tt[k] " " $c["t_total_s"];   tm[k] = tm[k] " " $c["t_mosaico_s"]
  tc[k] = tc[k] " " $c["t_catalogo_s"]; te[k] = te[k] " " $c["t_externo_s"]
  par[k] = $c["celda"] " " $c["tile"] " " $c["tiles_catalogo"]
  h = $c["hash_salida"]; if (!(k in hs)) hs[k] = h; else if (hs[k] != h) hs[k] = "VARIA" }
END { for (i = 1; i <= nk; i++) { k = o[i]; split(k, p, SUBSEP)
    printf "%s,%s,%d,%.6f,%.6f,%.6f,%.6f,%s,%s\n", p[1], p[2], n[k],
        med(tt[k]), med(tm[k]), med(tc[k]), med(te[k]), hs[k], par[k] } }'

echo "opt,imagen_id,n,t_total_s_mediana,t_mosaico_s_mediana,t_catalogo_s_mediana,t_externo_s_mediana,hash_salida,celda_tile_tiles" > "$TABLA"
awk -F, -v IMPL=neon "$MEDIANAS" "$CSV" | sort -t, -k2,2 -k1,1 >> "$TABLA"

# ------------------------------------------------------------ speedup vs escalar
if [ -f "$ESCALAR_CSV" ]; then
    awk -F, -v IMPL=escalar "$MEDIANAS" "$ESCALAR_CSV" > "$TMP/esc.csv"
    if [ -s "$TMP/esc.csv" ]; then
        echo "imagen_id,opt,metrica,escalar_mediana,neon_mediana,speedup,reduccion_pct,comparacion_principal" > "$SPEEDUP"
        awk -F, '
            NR == FNR { e[$1","$2] = $0; next }
            FNR == 1 { next }
            ($1","$2) in e {
                split(e[$1","$2], s, ",")
                if (s[9] != $9) printf "AVISO: %s -%s: celda/tile/tiles NEON=%s vs escalar=%s -> speedup NO comparable\n", $2, $1, $9, s[9] > "/dev/stderr"
                m[1] = "t_total_s"; m[2] = "t_mosaico_s"; m[3] = "t_catalogo_s"; m[4] = "t_externo_s"
                for (j = 1; j <= 4; j++) { a = s[j+3]; b = $(j+3)
                    if (b > 0 && a > 0) printf "%s,%s,%s,%.6f,%.6f,%.4f,%.2f,%s\n",
                        $2, $1, m[j], a, b, a/b, (a-b)/a*100, ($1 == "O2") ? "si" : "no" } }' \
            "$TMP/esc.csv" "$TABLA" | sort -t, -k1,1 -k2,2 -k3,3 >> "$SPEEDUP"
    fi
fi

# ------------------------------------------------------------ verificacion vs escalar
# El hash de la Etapa 3 no es comparable con el de medicion.h, asi que se
# compara el JPG generado por la escalar y por NEON (-O2, mismas banderas).
if [ -f "$ESCALAR_SRC" ] && echo " $OPTS " | grep -q ' O2 '; then
    inc=$(dirname "$ESCALAR_SRC")
    if $CC $CFLAGS -O2 -I"$inc" -I"$(dirname "$SRC")" "$ESCALAR_SRC" -o "$BIN_DIR/fotomosaico_escalar_O2" -lm 2>"$TMP/cc.err"; then
        echo "imagen_id,opt,jpg_neon_igual_a_escalar" > "$VERIF"
        for img in $IMAGENES; do
            id=$(basename "$img"); id=${id%.*}
            echo "[verificacion] $id"
            "${PIN[@]}" "$BIN_DIR/fotomosaico_escalar_O2" "$img" "$CATALOGO" "$TMP/esc.jpg" "$CELDA" "$TILE" >/dev/null 2>&1
            cmp -s "$TMP/esc.jpg" "$SALIDA_DIR/salidas/${id}_neon_O2_r1.jpg" && r=si || r=NO
            echo "$id,O2,$r" >> "$VERIF"
        done
    else
        echo "AVISO: no se pudo compilar $ESCALAR_SRC para verificar (ver abajo); se omite." >&2
        head -3 "$TMP/cc.err" >&2
    fi
fi

# ------------------------------------------------------------ perfil (opcional)
if [ "$PERFIL" = 1 ]; then
    if [ "$HAY_PERF" = 1 ] && echo " $OPTS " | grep -q ' O2 '; then
        PDIR=$SALIDA_DIR/perfil; mkdir -p "$PDIR"
        $CC $CFLAGS -O2 -fno-inline -fno-omit-frame-pointer "$SRC" -o "$BIN_DIR/fotomosaico_neon_O2_noinline" -lm
        echo "imagen_id,variante,funcion,porcentaje_muestras" > "$PDIR/funciones_top_neon.csv"
        for img in $IMAGENES; do
            id=$(basename "$img"); id=${id%.*}
            for var in O2 O2_noinline; do
                b="$BIN_DIR/fotomosaico_neon_$var"; tag="${id}_neon_${var}"
                echo "[perfil] $tag"
                perf stat -d -o "$PDIR/${tag}_stat.txt" -- "${PIN[@]}" "$b" "$img" "$CATALOGO" "$TMP/p.jpg" "$CELDA" "$TILE" >/dev/null 2>&1
                perf record -F 999 -g -o "$PDIR/${tag}.data" -- "${PIN[@]}" "$b" "$img" "$CATALOGO" "$TMP/p.jpg" "$CELDA" "$TILE" >/dev/null 2>&1
                perf report -i "$PDIR/${tag}.data" --stdio --no-children -g none --sort symbol > "$PDIR/${tag}_report.txt" 2>/dev/null
                awk -v id="$id" -v var="neon_$var" '/^ +[0-9.]+%/{p=$1; sub(/%/,"",p); print id","var","$NF","p; c++} c>=15{exit}' \
                    "$PDIR/${tag}_report.txt" >> "$PDIR/funciones_top_neon.csv"
            done
        done
        echo "Perfiles -> $PDIR"
    else
        echo "AVISO: sin perf (o sin -O2 en OPTS); se omite el perfil." >&2
    fi
fi

# ------------------------------------------------------------ consola
tabla() { column -s, -t 2>/dev/null || cat; }
echo
echo "Corridas: $(( $(wc -l < "$CSV") - 1 )) ok, $fallos fallidas -> $CSV"
echo; echo "Medianas NEON -> $TABLA"; tabla < "$TABLA"
if [ -s "$SPEEDUP" ]; then
    echo; echo "Speedup vs escalar ($ESCALAR_CSV) -> $SPEEDUP"
    grep -E '^imagen|,t_total_s,|,t_mosaico_s,' "$SPEEDUP" | tabla
else
    echo; echo "(No se encontro $ESCALAR_CSV con filas 'escalar': sin speedup. Use ESCALAR_CSV=ruta)"
fi
[ -s "$VERIF" ] && { echo; echo "Verificacion JPG NEON vs escalar -> $VERIF"; tabla < "$VERIF"; }
exit 0
