#!/usr/bin/env bash
set -u

REPS="${REPS:-5}"
CELL="${CELL:-10}"
TILE="${TILE:-20}"
CPU="${CPU:-2}"
CATALOG="${CATALOG:-../val2017}"
IMAGES="${IMAGES:-../imagenes_prueba/prueba1.jpg ../imagenes_prueba/prueba2.jpg}"
RESULTS_DIR="${RESULTS_DIR:-resultados/resultados exp3_4}"
BIN_DIR="${BIN_DIR:-bin}"
USE_PERF="${USE_PERF:-auto}"
PERF_EVENTS="${PERF_EVENTS:-task-clock,context-switches,cpu-migrations,page-faults,cycles,instructions,branches,branch-misses,cache-references,cache-misses}"

mkdir -p "$RESULTS_DIR" "$RESULTS_DIR/salidas" "$RESULTS_DIR/perfil"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

die() { echo "ERROR: $*" >&2; exit 1; }

[ -d "$CATALOG" ] || die "No existe el catalogo: $CATALOG"
for img in $IMAGES; do
    [ -f "$img" ] || die "No existe la imagen: $img"
done

if ! command -v /usr/bin/time >/dev/null 2>&1; then
    die "Se requiere /usr/bin/time"
fi

HAVE_PERF=0
if command -v perf >/dev/null 2>&1 &&
   perf stat -x, -e cycles true >/dev/null 2>"$TMP/perf_test"; then
    HAVE_PERF=1
fi

if [ "$USE_PERF" = "auto" ]; then
    USE_PERF="$HAVE_PERF"
elif [ "$USE_PERF" = "1" ] && [ "$HAVE_PERF" = "0" ]; then
    echo "AVISO: perf no esta disponible; se continuara sin contadores." >&2
    USE_PERF=0
fi

if [ "$CPU" != "-1" ] && command -v taskset >/dev/null 2>&1 &&
   taskset -c "$CPU" true >/dev/null 2>&1; then
    RUNNER="taskset -c $CPU"
else
    RUNNER=""
    [ "$CPU" != "-1" ] && echo "AVISO: no se puede fijar CPU $CPU; se continua sin taskset." >&2
    CPU="-1"
fi

temp_c() {
    if [ -r /sys/class/thermal/thermal_zone0/temp ]; then
        awk '{printf "%.1f",$1/1000}' /sys/class/thermal/thermal_zone0/temp
    else
        echo "NA"
    fi
}

freq_khz() {
    c="$CPU"
    [ "$c" = "-1" ] && c=0
    cat "/sys/devices/system/cpu/cpu${c}/cpufreq/scaling_cur_freq" 2>/dev/null || echo "NA"
}

perf_value() {
    file="$1"
    event="$2"
    awk -F, -v ev="$event" '
        {
            e=$3
            gsub(/[[:space:]]/,"",e)
            sub(/:u$/,"",e)
            sub(/:k$/,"",e)
            if (e==ev) {
                v=$1
                gsub(/[[:space:]]/,"",v)
                if (v=="" || v ~ /^</) v="NA"
                print v
                found=1
                exit
            }
        }
        END { if (!found) print "NA" }
    ' "$file"
}

HEADER="impl,opt,image_id,run,fecha,cpu_fijado,temp_c_antes,freq_khz_antes,t_external_s,width,height,cell,tile,tiles_catalogo,cols,rows,cells,evaluations_distance,exit_code,t_load_s,t_catalog_s,t_mosaic_s,t_write_s,t_total_s,cpu_time_s,max_rss_kb,hash_salida,out_width,out_height,perf_task_clock_ms,perf_context_switches,perf_cpu_migrations,perf_page_faults,perf_cycles,perf_instructions,perf_branches,perf_branch_misses,perf_cache_references,perf_cache_misses"

run_one() {
    impl="$1"
    opt="$2"
    level="$3"
    image="$4"
    run="$5"
    bin="$6"
    csv="$7"

    id="$(basename "$image")"
    id="${id%.*}"
    prog="$TMP/program.csv"
    perf_file="$TMP/perf.csv"
    perf_err="$TMP/perf.err"
    time_file="$TMP/time.txt"
    out="$TMP/out.jpg"
    rm -f "$prog" "$perf_file" "$perf_err" "$time_file" "$out"

    t0_date="$(date -Iseconds)"
    temp="$(temp_c)"
    freq="$(freq_khz)"

    cmd="env BUILD_OPT=$opt IMAGE_ID=$id $RUNNER \"$bin\" \"$image\" \"$CATALOG\" \"$out\" \"$CELL\" \"$TILE\""

    if [ "$USE_PERF" = "1" ]; then
        /usr/bin/time -f '%e' -o "$time_file" \
            perf stat -x, -o "$perf_file" -e "$PERF_EVENTS" -- \
            env BUILD_OPT="$opt" IMAGE_ID="$id" $RUNNER \
            "$bin" "$image" "$CATALOG" "$out" "$CELL" "$TILE" \
            >"$prog" 2>"$perf_err"
        rc=$?
    else
        /usr/bin/time -f '%e' -o "$time_file" \
            env BUILD_OPT="$opt" IMAGE_ID="$id" $RUNNER \
            "$bin" "$image" "$CATALOG" "$out" "$CELL" "$TILE" \
            >"$prog" 2>"$perf_err"
        rc=$?
    fi

    [ -s "$time_file" ] && t_ext="$(cat "$time_file")" || t_ext="NA"

    if [ "$rc" -ne 0 ] || [ ! -s "$prog" ]; then
        echo "FALLO impl=$impl opt=$opt nivel=$level imagen=$id corrida=$run rc=$rc" >&2
        cat "$perf_err" >&2 || true
        return 1
    fi

    # Conserva una copia de una salida representativa del nivel final O2.
    if [ "$impl" = "neon" ] && [ "$level" = "3" ] && [ "$opt" = "O2" ] && [ "$run" = "1" ]; then
        cp "$out" "$RESULTS_DIR/salidas/${id}_NEON_O2.jpg"
    fi

    # El programa imprime: impl,opt,image_id,<resto de campos>.
    prefix="$(cut -d, -f1-3 "$prog")"
    tail="$(cut -d, -f4- "$prog")"

    if [ "$USE_PERF" = "1" ] && [ -s "$perf_file" ]; then
        p1="$(perf_value "$perf_file" task-clock)"
        p2="$(perf_value "$perf_file" context-switches)"
        p3="$(perf_value "$perf_file" cpu-migrations)"
        p4="$(perf_value "$perf_file" page-faults)"
        p5="$(perf_value "$perf_file" cycles)"
        p6="$(perf_value "$perf_file" instructions)"
        p7="$(perf_value "$perf_file" branches)"
        p8="$(perf_value "$perf_file" branch-misses)"
        p9="$(perf_value "$perf_file" cache-references)"
        p10="$(perf_value "$perf_file" cache-misses)"
    else
        p1="NA"; p2="NA"; p3="NA"; p4="NA"; p5="NA"
        p6="NA"; p7="NA"; p8="NA"; p9="NA"; p10="NA"
    fi

    awk -v run="$run" -v fecha="$t0_date" -v cpu="$CPU" -v temp="$temp" \
        -v freq="$freq" -v ext="$t_ext" \
        -v p1="$p1" -v p2="$p2" -v p3="$p3" -v p4="$p4" -v p5="$p5" \
        -v p6="$p6" -v p7="$p7" -v p8="$p8" -v p9="$p9" -v p10="$p10" \
        'BEGIN{FS=OFS=","}
         {print $1,$2,$3,run,fecha,cpu,temp,freq,ext,
               $4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,
               p1,p2,p3,p4,p5,p6,p7,p8,p9,p10}' "$prog" >> "$csv"

}

write_csv_for_level() {
    level="$1"
    csv="$RESULTS_DIR/medicion_${level}optimizacion.csv"
    echo "$HEADER" > "$csv"

    total=$((REPS * 2 * 3))
    n=0

    for run in $(seq 1 "$REPS"); do
        for image in $IMAGES; do
            for opt in O0 O2 O3; do
                n=$((n+1))
                bin="$BIN_DIR/fotomosaico_neon_N${level}_${opt}"
                printf '[NEON nivel %s %3d/%3d] %s %s corrida=%d\n' \
                    "$level" "$n" "$total" "$(basename "$image")" "$opt" "$run"
                run_one neon "$opt" "$level" "$image" "$run" "$bin" "$csv" || true
            done
        done
    done

    [ "$(wc -l < "$csv")" -gt 1 ] || die "No se obtuvieron mediciones para $csv"
}

run_scalar() {
    csv="$RESULTS_DIR/mediciones_escalar.csv"
    echo "$HEADER" > "$csv"

    total=$((REPS * 2 * 3))
    n=0

    for run in $(seq 1 "$REPS"); do
        for image in $IMAGES; do
            for opt in O0 O2 O3; do
                n=$((n+1))
                bin="$BIN_DIR/fotomosaico_escalar_${opt}"
                printf '[ESCALAR %3d/%3d] %s %s corrida=%d\n' \
                    "$n" "$total" "$(basename "$image")" "$opt" "$run"
                run_one scalar "$opt" 0 "$image" "$run" "$bin" "$csv" || true
            done
        done
    done

    [ "$(wc -l < "$csv")" -gt 1 ] || die "No se obtuvieron mediciones escalares"
}

echo "Fecha: $(date -Iseconds)" > "$RESULTS_DIR/metadatos.txt"
echo "Host: $(hostname)" >> "$RESULTS_DIR/metadatos.txt"
echo "CPU: $(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^ +/,"",$2);print $2;exit}' || echo NA)" >> "$RESULTS_DIR/metadatos.txt"
echo "Kernel: $(uname -a)" >> "$RESULTS_DIR/metadatos.txt"
echo "CC: $(${CC:-gcc} --version 2>/dev/null | head -1 || echo NA)" >> "$RESULTS_DIR/metadatos.txt"
echo "REPS=$REPS CELL=$CELL TILE=$TILE CPU=$CPU USE_PERF=$USE_PERF" >> "$RESULTS_DIR/metadatos.txt"
echo "CATALOG=$CATALOG" >> "$RESULTS_DIR/metadatos.txt"
echo "IMAGES=$IMAGES" >> "$RESULTS_DIR/metadatos.txt"
echo "PERF_EVENTS=$PERF_EVENTS" >> "$RESULTS_DIR/metadatos.txt"

run_scalar
write_csv_for_level 1
write_csv_for_level 2
write_csv_for_level 3

# Medianas y resultados del punto 4.
awk -F, '
function median(s, a,n,i,j,t) {
    n=split(s,a," ")
    for(i=2;i<=n;i++){t=a[i];j=i-1;while(j>0 && a[j]>t){a[j+1]=a[j];j--}a[j+1]=t}
    return (n%2)?a[(n+1)/2]:(a[n/2]+a[n/2+1])/2
}
NR==1 {for(i=1;i<=NF;i++) c[$i]=i; next}
$(c["exit_code"]) != 0 {next}
{
    k=$(c["impl"]) SUBSEP $(c["opt"]) SUBSEP $(c["image_id"])
    n[k]++
    tt[k]=tt[k]" "$(c["t_total_s"])
    tm[k]=tm[k]" "$(c["t_mosaic_s"])
}
END{
    print "impl,opt,image_id,n,t_total_s_mediana,t_mosaic_s_mediana"
    for(k in n){
        split(k,p,SUBSEP)
        printf "%s,%s,%s,%d,%.6f,%.6f\n",p[1],p[2],p[3],n[k],median(tt[k]),median(tm[k])
    }
}' "$RESULTS_DIR/mediciones_escalar.csv" \
 | sort -t, -k3,3 -k2,2 > "$TMP/scalar_medians.csv"

for level in 1 2 3; do
    awk -F, -v L="$level" '
    function median(s,a,n,i,j,t){
        n=split(s,a," ")
        for(i=2;i<=n;i++){t=a[i];j=i-1;while(j>0&&a[j]>t){a[j+1]=a[j];j--}a[j+1]=t}
        return (n%2)?a[(n+1)/2]:(a[n/2]+a[n/2+1])/2
    }
    NR==1 {for(i=1;i<=NF;i++) c[$i]=i;next}
    $(c["exit_code"])!=0{next}
    {
        k=$(c["opt"]) SUBSEP $(c["image_id"])
        n[k]++;tt[k]=tt[k]" "$(c["t_total_s"]);tm[k]=tm[k]" "$(c["t_mosaic_s"])
    }
    END{
        print "level,opt,image_id,n,t_total_s_mediana,t_mosaic_s_mediana"
        for(k in n){split(k,p,SUBSEP);printf "%s,%s,%s,%d,%.6f,%.6f\n",L,p[1],p[2],n[k],median(tt[k]),median(tm[k])}
    }' "$RESULTS_DIR/medicion_${level}optimizacion.csv" \
    | sort -t, -k3,3 -k2,2 > "$TMP/neon${level}_medians.csv"
done

{
    echo "implementacion,opt,imagen_id,t_total_s_mediana,t_mosaic_s_mediana"
    for implopt in \
        "escalar,O0" "escalar,O2" "escalar,O3" \
        "neon1,O0" "neon1,O2" "neon1,O3" \
        "neon2,O0" "neon2,O2" "neon2,O3" \
        "neon3,O0" "neon3,O2" "neon3,O3"; do
        impl="${implopt%,*}"; opt="${implopt#*,}"
        if [[ "$impl" == escalar ]]; then file="$TMP/scalar_medians.csv"; else file="$TMP/${impl}_medians.csv"; fi
        awk -F, -v O="$opt" -v I="$impl" 'NR>1 && $2==O {printf "%s,%s,%s,%.6f,%.6f\n",I,O,$3,$5,$6}' "$file"
    done
} > "$RESULTS_DIR/tabla_mediana_tiempos.csv"

# Tabla exigida en el enunciado: solo la version final NEON nivel 3.
awk -F, '
NR==1 {next}
{
    if ($1=="escalar" || $1=="neon3") {
        k=$2 SUBSEP $3
        v[k]=$4
    }
}
END{
    print "Implementacion,Imagen1_t_total_s,Imagen2_t_total_s"
    for(j=1;j<=3;j++){
        if(j==1)o="O0"; else if(j==2)o="O2"; else o="O3"
        printf "Escalar -%s,%s,%s\n",o,v[o SUBSEP "prueba1"],v[o SUBSEP "prueba2"]
        printf "NEON -%s,%s,%s\n",o,v[o SUBSEP "prueba1"],v[o SUBSEP "prueba2"]
    }
}' "$RESULTS_DIR/tabla_mediana_tiempos.csv" \
    > "$RESULTS_DIR/tabla_punto4.csv"

# Speedup y reduccion: comparacion principal O2, por imagen.
awk -F, '
NR==1 {next}
{
    if ($1=="escalar" && $2=="O2") {s[$3]=$4; sm[$3]=$5}
    if ($1=="neon3" && $2=="O2") n[$3]=$4
}
END{
    print "imagen_id,t_escalar_O2_s,t_neon_O2_s,speedup,reduccion_pct"
    for(i in s)
        if (n[i]>0)
            printf "%s,%.6f,%.6f,%.6f,%.2f\n",i,s[i],n[i],s[i]/n[i],(s[i]-n[i])/s[i]*100
}' "$RESULTS_DIR/tabla_mediana_tiempos.csv" \
    | sort -t, -k1,1 > "$RESULTS_DIR/speedup_punto4.csv"

# Punto 3: efecto incremental de cada nivel de optimizacion a O2.
awk -F, '
NR==1 {next}
{
    if ($1=="escalar" && $2=="O2") {s[$3]=$4; sm[$3]=$5}
    if ($1=="neon1" && $2=="O2") {n1[$3]=$4; n1m[$3]=$5}
    if ($1=="neon2" && $2=="O2") {n2[$3]=$4; n2m[$3]=$5}
    if ($1=="neon3" && $2=="O2") {n3[$3]=$4; n3m[$3]=$5}
}
END{
    print "imagen_id,nivel,t_total_neon_s,t_mosaic_neon_s,speedup_total_vs_escalar,reduccion_total_pct,speedup_mosaic_vs_escalar,reduccion_mosaic_pct,speedup_total_vs_nivel_anterior,reduccion_total_vs_nivel_anterior_pct"
    for(i in s){
        prev=s[i]
        if(n1[i]>0){printf "%s,1,%.6f,%.6f,%.6f,%.2f,%.6f,%.2f,%.6f,%.2f\n",i,n1[i],n1m[i],s[i]/n1[i],(s[i]-n1[i])/s[i]*100,sm[i]/n1m[i],(sm[i]-n1m[i])/sm[i]*100,prev/n1[i],(prev-n1[i])/prev*100;prev=n1[i]}
        if(n2[i]>0){printf "%s,2,%.6f,%.6f,%.6f,%.2f,%.6f,%.2f,%.6f,%.2f\n",i,n2[i],n2m[i],s[i]/n2[i],(s[i]-n2[i])/s[i]*100,sm[i]/n2m[i],(sm[i]-n2m[i])/sm[i]*100,prev/n2[i],(prev-n2[i])/prev*100;prev=n2[i]}
        if(n3[i]>0){printf "%s,3,%.6f,%.6f,%.6f,%.2f,%.6f,%.2f,%.6f,%.2f\n",i,n3[i],n3m[i],s[i]/n3[i],(s[i]-n3[i])/s[i]*100,sm[i]/n3m[i],(sm[i]-n3m[i])/sm[i]*100,prev/n3[i],(prev-n3[i])/prev*100}
    }
}' "$RESULTS_DIR/tabla_mediana_tiempos.csv" \
    | sort -t, -k1,1 -k2,2n > "$RESULTS_DIR/resumen_punto3.csv"

# Medianas de contadores para NEON final O2.
awk -F, '
function median(s,a,b,n,i,j,t,k){n=split(s,a," ");k=0;for(i=1;i<=n;i++)if(a[i] ~ /^-?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$/)b[++k]=a[i]+0;if(k==0)return "NA";for(i=2;i<=k;i++){t=b[i];j=i-1;while(j>0&&b[j]>t){b[j+1]=b[j];j--}b[j+1]=t}return(k%2)?b[(k+1)/2]:(b[k/2]+b[k/2+1])/2}
NR==1{for(i=1;i<=NF;i++)c[$i]=i;next}
$(c["opt"])!="O2" || $(c["exit_code"])!=0{next}
{
 k=$(c["impl"]) SUBSEP $(c["image_id"])
 n[k]++
 a[k]=a[k]" "$(c["perf_task_clock_ms"])
 b[k]=b[k]" "$(c["perf_cycles"])
 d[k]=d[k]" "$(c["perf_instructions"])
 e[k]=e[k]" "$(c["perf_branches"])
 f[k]=f[k]" "$(c["perf_branch_misses"])
 g[k]=g[k]" "$(c["perf_cache_references"])
 h[k]=h[k]" "$(c["perf_cache_misses"])
}
END{
 print "impl,image_id,n,task_clock_ms_mediana,cycles_mediana,instructions_mediana,branches_mediana,branch_misses_mediana,cache_references_mediana,cache_misses_mediana"
 for(k in n){split(k,p,SUBSEP);printf "%s,%s,%d,%s,%s,%s,%s,%s,%s,%s\n",p[1],p[2],n[k],median(a[k]),median(b[k]),median(d[k]),median(e[k]),median(f[k]),median(g[k]),median(h[k])}
}' "$RESULTS_DIR/medicion_3optimizacion.csv" \
    | sort -t, -k2,2 -k1,1 > "$RESULTS_DIR/medianas_perf_neon_O2.csv"

if [ ! -f "$RESULTS_DIR/registro_optimizaciones.csv" ]; then
cat > "$RESULTS_DIR/registro_optimizaciones.csv" <<'EOF'
nivel,optimizacion,descripcion,tiempo_implementacion_min,tiempo_evaluacion_min,observaciones
1,NEON promedio_catalogo,"Vectorizacion de average_color con vld3q_u8/vaddlvq_u8",,,
2,NEON busqueda_catalogo,"Vectorizacion de find_best_tile para 4 candidatos por iteracion",,,
3,NEON promedio_celda,"Vectorizacion de cell_average en bloques de 16 pixeles",,,
EOF
fi

echo
echo "Resultados generados en: $RESULTS_DIR"
echo "  medicion_1optimizacion.csv"
echo "  medicion_2optimizacion.csv"
echo "  medicion_3optimizacion.csv"
echo "  mediciones_escalar.csv"
echo "  tabla_punto4.csv"
echo "  speedup_punto4.csv"
echo "  resumen_punto3.csv"
echo "  medianas_perf_neon_O2.csv"
