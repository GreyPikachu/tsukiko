// Считает токены подсказок штатным токенизатором whisper.cpp 1.9.3.
// Собирается локально сценарием asr_stress.py из уже подготовленного движка.
#include "whisper.h"

#include <iostream>
#include <string>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    auto params = whisper_context_default_params();
    params.use_gpu = false;
    auto *ctx = whisper_init_from_file_with_params_no_state(argv[1], params);
    if (!ctx) return 3;
    std::cout << "budget " << whisper_n_text_ctx(ctx) / 2 << std::endl;
    std::string line;
    while (std::getline(std::cin, line)) {
        std::cout << whisper_token_count(ctx, line.c_str()) << std::endl;
    }
    whisper_free(ctx);
    return 0;
}
