/*
 * Real MPI program for knit integration test 04_submit_mpi.
 *
 * Every rank contributes its own rank id to an MPI_Allreduce(SUM) over
 * MPI_COMM_WORLD. If the ranks genuinely communicate, every rank obtains the
 * same global sum 0 + 1 + ... + (size - 1) = size * (size - 1) / 2. Each rank
 * prints exactly one line:
 *
 *     RANK=<r> SIZE=<n> SUM=<s> HOST=<host>
 *
 * so the driver can verify the rank set, the world size, the collective result
 * (the actual proof of inter-rank communication), and the multi-node placement.
 * Compiled against the cluster's MPI (via mpicc) by the "mpienv" setup and
 * launched across nodes by `knit run`.
 */
#include <mpi.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    int rank = 0, size = 0, sum = -1;
    char host[256] = "unknown";

    MPI_Init(&argc, &argv);
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    /* The real inter-rank communication this test exists to exercise. */
    MPI_Allreduce(&rank, &sum, 1, MPI_INT, MPI_SUM, MPI_COMM_WORLD);

    gethostname(host, sizeof(host));
    printf("RANK=%d SIZE=%d SUM=%d HOST=%s\n", rank, size, sum, host);
    fflush(stdout);

    MPI_Finalize();
    return 0;
}
