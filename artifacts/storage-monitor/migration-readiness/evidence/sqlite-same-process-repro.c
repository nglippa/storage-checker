// Same-process SQLite lock failure reproduction (no Storage Monitor code). Build: clang -O2 -o repro sqlite-same-process-repro.c -lsqlite3
// Run: ./repro /private/tmp/x/db MODE   (MODE 0 no reader, 1 read-only reader thread reopening, 2 reader in a separate process,
//      3 one persistent read-only connection, 4 read-only reopening with FULLMUTEX, 5 read-write reader reopening). Delete db between runs.

#include <signal.h>
#include <sys/wait.h>
#include <sqlite3.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdatomic.h>
static const char *path; static atomic_int stop = 0; static atomic_int logged = 0;
static void logcb(void *p, int code, const char *msg) { if (0 && logged++ < 12) fprintf(stderr, "sqlite log: extended code %d (primary %d): %s\n", code, code & 0xff, msg); }
static int progress(void *p) { return 0; }
static int fullmutex = 0; static int readwrite = 0;
static void *persistent(void *x) {
  int n = 0, fails = 0; sqlite3 *db = NULL;
  sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL); sqlite3_busy_timeout(db, 100);
  while (!stop) { if (sqlite3_exec(db, "SELECT COUNT(*) FROM t", 0, 0, 0) != SQLITE_OK) fails++; n++; usleep(500); }
  sqlite3_close(db); fprintf(stderr, "reader: %d reads, %d failed\n", n, fails); return NULL;
}
static void *reader(void *mode) {
  int same = mode != NULL, n = 0, fails = 0;
  while (!stop) {
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path, &db, (readwrite ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY) | (fullmutex ? SQLITE_OPEN_FULLMUTEX : SQLITE_OPEN_NOMUTEX), NULL) == SQLITE_OK) {
      sqlite3_busy_timeout(db, 100); sqlite3_progress_handler(db, 1000, progress, NULL);
      sqlite3_exec(db, "PRAGMA query_only=ON; PRAGMA foreign_keys=ON;", 0, 0, 0);
      if (sqlite3_exec(db, "SELECT COUNT(*) FROM t", 0, 0, 0) != SQLITE_OK) fails++;
      n++;
    }
    sqlite3_close(db);
    usleep(500);
  }
  fprintf(stderr, "reader: %d reads, %d failed\n", n, fails); return NULL;
}
int main(int argc, char **argv) {
  path = argv[1]; int withReader = atoi(argv[2]);
  sqlite3_config(SQLITE_CONFIG_LOG, logcb, NULL);
  fullmutex = withReader == 4; readwrite = withReader == 5; sqlite3 *w; sqlite3_open_v2(path, &w, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | (fullmutex ? SQLITE_OPEN_FULLMUTEX : SQLITE_OPEN_NOMUTEX), NULL);
  sqlite3_extended_result_codes(w, 1); sqlite3_busy_timeout(w, 30000);
  sqlite3_exec(w, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS t(v BLOB);", 0, 0, 0);
  pthread_t th; pid_t child = 0;
  if (withReader == 1 || withReader == 4 || withReader == 5) pthread_create(&th, NULL, reader, NULL);
  if (withReader == 3) pthread_create(&th, NULL, persistent, NULL);
  if (withReader == 2) { child = fork(); if (child == 0) { reader(NULL); _exit(0); } }
  int errors = 0;
  for (int i = 0; i < 3000; i++) {
    int rc = sqlite3_exec(w, "BEGIN IMMEDIATE; INSERT INTO t VALUES(randomblob(2000)); COMMIT;", 0, 0, 0);
    if (rc != SQLITE_OK) { if (errors++ < 3) fprintf(stderr, "writer txn %d: extended=%d errno=%d (%s)\n", i, sqlite3_extended_errcode(w), sqlite3_system_errno(w), strerror(sqlite3_system_errno(w))); sqlite3_exec(w, "ROLLBACK", 0, 0, 0); }
  }
  stop = 1; if (withReader == 1 || withReader == 3 || withReader == 4 || withReader == 5) pthread_join(th, NULL); if (child) { kill(child, SIGTERM); waitpid(child, NULL, 0); }
  fprintf(stderr, "writer: 3000 transactions, %d failed (reader in same process: %s)\n", errors, withReader == 1 ? "same process, reopening" : withReader == 2 ? "separate process" : withReader == 3 ? "same process, one persistent connection" : withReader == 4 ? "same process, reopening, FULLMUTEX" : withReader == 5 ? "same process, reopening, READWRITE reader" : "none");
  sqlite3_close(w); return 0;
}
