// Copyright 2019 Beckman Coulter, Inc.
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

#include <assert.h>
#include "swish.h"

#define MAX_THREADS 128

typedef struct {
  uv_thread_t tid;
  int number;
  int iterations;
  char* cb_name;
} test_thread_t;

typedef struct {
  int rep;
  char* cb_name;
  int who;
} payload_t;

static test_thread_t thread[MAX_THREADS];
static int thread_count = 0;

static void handle_request(void* arg) {
  payload_t* payload = (payload_t*)arg;
  ptr callback = Stop_level_value(Sstring_to_symbol(payload->cb_name));
  assert(Sprocedurep(callback));
  ptr ls = Scons(Sfixnum(payload->who), Scons(Sfixnum(payload->rep), Snil));
  osi_add_callback_list(callback, ls);
}

EXPORT ptr add_work(int iterations, char* cb_name) {
  if (iterations < 0 || MAX_THREADS == thread_count)
    return Sfalse;
  thread[thread_count].number = thread_count;
  thread[thread_count].iterations = iterations;
  thread[thread_count].cb_name = cb_name;
  thread_count++;
  return Strue;
}

static void do_work(void* arg) {
  test_thread_t* thread = (test_thread_t*)arg;
  char* cb_name = thread->cb_name;
  for (int i = thread->iterations; i >= 0; i--) {
    // local okay since osi_send_request blocks until handle_request returns
    payload_t payload = { .cb_name = cb_name, .rep = i, .who = thread->number };
    osi_send_request(handle_request, &payload);
  }
}

EXPORT ptr create_threads() {
  for (int i = 0; i < thread_count; i++) {
    if (uv_thread_create(&thread[i].tid, do_work, &thread[i]))
      return Sfalse;
  }
  return Strue;
}

EXPORT void join_threads() {
  while (thread_count) {
    uv_thread_join(&thread[--thread_count].tid);
  }
}
