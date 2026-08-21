/* Tiny MPI hello-world for knit profile validation.
 *
 * Each rank prints one parseable line:
 *
 *     RANK=<r> SIZE=<n> HOST=<hostname>
 *
 * so the harness (check.sh) can confirm that the ranks are distinct, complete
 * (0..n-1), agree on the world size, and are spread across the allocated nodes.
 *
 * The program does its own MPI_Init, so it reports the rank the launcher gave
 * it. When it runs as a child of a knit app rank it inherits that rank's PMI
 * environment and joins the same world -- which is exactly what proves the
 * profile's launcher places processes correctly.
 */
#include <mpi.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    int rank = 0;
    int size = 0;
    char host[256];

    MPI_Init(&argc, &argv);
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    if (gethostname(host, sizeof(host)) != 0) {
        host[0] = '\0';
    }
    host[sizeof(host) - 1] = '\0';

    printf("RANK=%d SIZE=%d HOST=%s\n", rank, size, host);
    fflush(stdout);

    MPI_Finalize();
    return 0;
}
