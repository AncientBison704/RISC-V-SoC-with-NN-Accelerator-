#include "nn_weights.h"

#define UART_TX ((volatile unsigned int *)0x10000000)

// NN Accelerator registers
#define NN_BASE     0x20000000
#define NN_CTRL     (*(volatile unsigned int *)(NN_BASE + 0x000))
#define NN_STATUS   (*(volatile unsigned int *)(NN_BASE + 0x004))
#define NN_CONFIG   (*(volatile unsigned int *)(NN_BASE + 0x008))
#define NN_RESULT   (*(volatile unsigned int *)(NN_BASE + 0x00C))
#define NN_CYCLES   (*(volatile unsigned int *)(NN_BASE + 0x010))
#define NN_WEIGHTS  ((volatile unsigned int *)(NN_BASE + 0x400))
#define NN_ACT_IN   ((volatile unsigned int *)(NN_BASE + 0x800))
#define NN_ACT_OUT  ((volatile unsigned int *)(NN_BASE + 0xA00))
#define NN_BIAS     ((volatile unsigned int *)(NN_BASE + 0xC00))

void print_str(const char *s) {
    while (*s) *UART_TX = *s++;
}

void print_hex(unsigned int val) {
    for (int i = 28; i >= 0; i -= 4) {
        unsigned int n = (val >> i) & 0xF;
        *UART_TX = n < 10 ? '0' + n : 'A' + n - 10;
    }
}

void print_dec(int val) {
    if (val < 0) { *UART_TX = '-'; val = -val; }
    char buf[12];
    int i = 0;
    do { buf[i++] = '0' + (val % 10); val /= 10; } while (val);
    while (i--) *UART_TX = buf[i];
}

// Load packed weight array into accelerator weight memory
void load_weights(const unsigned int *src, int num_words) {
    for (int i = 0; i < num_words; i++)
        NN_WEIGHTS[i] = src[i];
}

// Load packed bias array into accelerator bias memory
void load_biases(const unsigned int *src, int num_words) {
    for (int i = 0; i < num_words; i++)
        NN_BIAS[i] = src[i];
}

// Load packed input activations
void load_activations(const unsigned int *src, int num_words) {
    for (int i = 0; i < num_words; i++)
        NN_ACT_IN[i] = src[i];
}

// Copy output activations to input for next layer
void copy_output_to_input(int num_words) {
    for (int i = 0; i < num_words; i++)
        NN_ACT_IN[i] = NN_ACT_OUT[i];
}

// Run one layer through the accelerator
// Returns 0 on success, -1 on timeout
int run_layer(int input_len, int num_neurons, int relu) {
    // Configure
    unsigned int config = (input_len & 0x3FF)
                        | ((num_neurons & 0x3FF) << 10)
                        | ((relu & 1) << 20);
    NN_CONFIG = config;

    // Start
    NN_CTRL = 1;

    // Poll
    int timeout = 500000;
    while (!(NN_STATUS & 0x2) && --timeout);

    return (timeout == 0) ? -1 : 0;
}

int main(void) {
    print_str("== RISC-V NN SoC ==\n");
    print_str("Week 4: Multi-layer MNIST Inference\n");
    print_str("Network: 16 -> 16 (ReLU) -> 10\n\n");

    int passed = 0;
    int total = NN_NUM_TESTS;

    for (int t = 0; t < NN_NUM_TESTS; t++) {
        print_str("--- Test ");
        print_dec(t);
        print_str(" (label=");
        print_dec(nn_test_labels[t]);
        print_str(") ---\n");

        // ── Layer 1: input(16) → hidden(16), ReLU ──

        // Load layer 1 weights: HIDDEN_SIZE * INPUT_SIZE / 2 words
        load_weights(nn_fc1_weights,
                     (NN_HIDDEN_SIZE * NN_INPUT_SIZE) / 2);

        // Load layer 1 biases: HIDDEN_SIZE / 2 words
        load_biases(nn_fc1_biases, NN_HIDDEN_SIZE / 2);

        // Load test input: INPUT_SIZE / 2 words
        load_activations(nn_test_inputs[t], NN_INPUT_SIZE / 2);

        // Run layer 1
        if (run_layer(NN_INPUT_SIZE, NN_HIDDEN_SIZE, 1) < 0) {
            print_str("  ERROR: Layer 1 timeout\n");
            continue;
        }

        unsigned int l1_cycles = NN_CYCLES;

        // ── Layer 2: hidden(16) → output(10), no ReLU ──

        // Copy layer 1 outputs to layer 2 inputs
        copy_output_to_input(NN_HIDDEN_SIZE / 2);

        // Load layer 2 weights: OUTPUT_SIZE * HIDDEN_SIZE / 2 words
        load_weights(nn_fc2_weights,
                     (NN_OUTPUT_SIZE * NN_HIDDEN_SIZE) / 2);

        // Load layer 2 biases: OUTPUT_SIZE / 2 words
        load_biases(nn_fc2_biases, NN_OUTPUT_SIZE / 2);

        // Run layer 2
        if (run_layer(NN_HIDDEN_SIZE, NN_OUTPUT_SIZE, 0) < 0) {
            print_str("  ERROR: Layer 2 timeout\n");
            continue;
        }

        unsigned int l2_cycles = NN_CYCLES;

        // Read result
        unsigned int result = NN_RESULT;
        unsigned int predicted = result & 0xFFFF;
        unsigned int golden = nn_golden_argmax[t];

        print_str("  L1 cycles: ");
        print_dec(l1_cycles);
        print_str(", L2 cycles: ");
        print_dec(l2_cycles);
        print_str("\n");

        print_str("  Predicted: ");
        print_dec(predicted);
        print_str(", Golden: ");
        print_dec(golden);

        if (predicted == golden) {
            print_str(" [MATCH]\n");
            passed++;
        } else {
            print_str(" [MISMATCH]\n");
            // Print all outputs for debugging
            print_str("  Outputs:");
            for (int i = 0; i < NN_OUTPUT_SIZE / 2; i++) {
                unsigned int word = NN_ACT_OUT[i];
                print_str(" 0x");
                print_hex(word);
            }
            print_str("\n");
        }
    }

    print_str("\n========================================\n");
    print_str("Results: ");
    print_dec(passed);
    print_str("/");
    print_dec(total);
    print_str(" matched golden model\n");

    if (passed == total)
        print_str("*** ALL TESTS PASSED ***\n");
    else
        print_str("*** SOME TESTS FAILED ***\n");

    print_str("========================================\n\nDone. Halting.\n");
    while (1);
    return 0;
}
