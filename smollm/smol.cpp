// Minimal SmolLM2 chat runner with llama2.c's CLI/output contract:
//   smol model.gguf [-n steps] -i "question"
// stdout: the assistant answer only, flushed per token.
// stderr: "achieved tok/s: X" (decode tokens/sec) as the very last output.
#include "llama.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s model.gguf [-n steps] -i question\n", argv[0]);
        return 1;
    }
    const char *path = argv[1], *q = "Why is the sky blue?";
    int steps = 200;
    for (int i = 2; i + 1 < argc; i += 2) {
        if (!strcmp(argv[i], "-n"))
            steps = atoi(argv[i + 1]);
        else if (!strcmp(argv[i], "-i"))
            q = argv[i + 1];
    }
    llama_log_set(
        [](ggml_log_level l, const char* t, void*) {
            if (l >= GGML_LOG_LEVEL_ERROR) fputs(t, stderr);
        },
        nullptr);
    ggml_backend_load_all();

    llama_model_params mp = llama_model_default_params();
    mp.progress_callback = [](float, void*) { return true; }; // no loading dots
    llama_model* model = llama_model_load_from_file(path, mp);
    if (!model) {
        fprintf(stderr, "cannot load %s\n", path);
        return 1;
    }
    const llama_vocab* vocab = llama_model_get_vocab(model);

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = 512;
    cp.n_batch = 512;
    cp.n_threads = cp.n_threads_batch = 1;
    llama_context* ctx = llama_init_from_model(model, cp);
    if (!ctx) {
        fprintf(stderr, "cannot create context\n");
        return 1;
    }

    // Low temperature + mild repetition penalty: a 135M model rambles otherwise.
    llama_sampler* smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(smpl, llama_sampler_init_top_k(40));
    llama_sampler_chain_add(smpl,
                            llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, 1.1f, 0.0f, 0.0f));
    llama_sampler_chain_add(smpl, llama_sampler_init_top_p(0.9f, 1));
    llama_sampler_chain_add(smpl, llama_sampler_init_temp(0.3f));
    llama_sampler_chain_add(smpl, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));

    llama_chat_message msgs[] = {{"system", "You are a helpful assistant."}, {"user", q}};
    std::vector<char> buf(4096);
    int len = llama_chat_apply_template(llama_model_chat_template(model, nullptr), msgs, 2, true, buf.data(),
                                        buf.size());
    if (len < 0 || len > (int)buf.size()) {
        fprintf(stderr, "chat template failed\n");
        return 1;
    }

    std::vector<llama_token> toks(len + 8);
    int n = llama_tokenize(vocab, buf.data(), len, toks.data(), toks.size(), true, true);
    if (n < 0 || n + steps > (int)cp.n_ctx) {
        fprintf(stderr, "prompt too long\n");
        return 1;
    }
    toks.resize(n);

    llama_batch batch = llama_batch_get_one(toks.data(), n);
    llama_token tok;
    int gen = 0;
    auto t0 = std::chrono::steady_clock::now(); // reset after prefill: decode-only tok/s
    for (; gen < steps; gen++) {
        if (llama_decode(ctx, batch)) {
            fprintf(stderr, "decode failed\n");
            return 1;
        }
        if (gen == 0) t0 = std::chrono::steady_clock::now();
        tok = llama_sampler_sample(smpl, ctx, -1);
        if (llama_vocab_is_eog(vocab, tok)) break;
        char piece[256];
        int m = llama_token_to_piece(vocab, tok, piece, sizeof piece, 0, false);
        if (m > 0) {
            fwrite(piece, 1, m, stdout);
            fflush(stdout);
        }
        batch = llama_batch_get_one(&tok, 1);
    }
    double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    fprintf(stderr, "\nachieved tok/s: %f\n", gen > 1 ? (gen - 1) / s : 0.0);
    return 0;
}
