#include <time.h>

int main(){

    clock_t inicio, final;
    inicio = clock();

    long N = 10000000000;
    for (int i =0; i <N; ++i){
        clock();
    }

    final = clock();

    printf("%f", (inicio-final/N));


}
