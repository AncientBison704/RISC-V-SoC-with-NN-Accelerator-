#!/usr/bin/env python3
"""
Train a small MNIST classifier and export Q8.8 weights for the RISC-V NN SoC.

Network: 16 inputs (4x4 downsampled MNIST) → 16 hidden (ReLU) → 10 output
Fixed-point: Q8.8 (signed 16-bit, 256 = 1.0)

Outputs:
  - fw/nn_weights.h   : C header with packed weight/bias arrays
  - python/golden.txt : golden model outputs for verification
"""

import torch
import torch.nn as nn
import torch.nn.functional as F
from torchvision import datasets, transforms
import numpy as np
import os
import struct

# ── Network ──────────────────────────────────────────────────────────────────

INPUT_SIZE = 16    # 4x4 downsampled
HIDDEN_SIZE = 16
OUTPUT_SIZE = 10

class SmallNet(nn.Module):
    def __init__(self):
        super().__init__()
        self.fc1 = nn.Linear(INPUT_SIZE, HIDDEN_SIZE)
        self.fc2 = nn.Linear(HIDDEN_SIZE, OUTPUT_SIZE)

    def forward(self, x):
        x = F.relu(self.fc1(x))
        x = self.fc2(x)
        return x

# ── Training ─────────────────────────────────────────────────────────────────

def downsample_4x4(img):
    """Downsample 28x28 MNIST to 4x4 by average pooling."""
    return F.avg_pool2d(img, kernel_size=7).view(-1, INPUT_SIZE)

def train():
    print("Loading MNIST...")
    transform = transforms.Compose([transforms.ToTensor()])

    try:
        train_set = datasets.MNIST('./data', train=True, download=True, transform=transform)
        test_set = datasets.MNIST('./data', train=False, download=True, transform=transform)
    except Exception as e:
        print(f"Cannot download MNIST: {e}")
        print("Using synthetic data instead...")
        return train_synthetic()

    train_loader = torch.utils.data.DataLoader(train_set, batch_size=128, shuffle=True)
    test_loader = torch.utils.data.DataLoader(test_set, batch_size=256, shuffle=False)

    model = SmallNet()
    optimizer = torch.optim.Adam(model.parameters(), lr=0.001)
    criterion = nn.CrossEntropyLoss()

    print("Training...")
    for epoch in range(10):
        model.train()
        total_loss = 0
        for images, labels in train_loader:
            x = downsample_4x4(images)
            optimizer.zero_grad()
            output = model(x)
            loss = criterion(output, labels)
            loss.backward()
            optimizer.step()
            total_loss += loss.item()

        # Evaluate
        model.eval()
        correct = 0
        total = 0
        with torch.no_grad():
            for images, labels in test_loader:
                x = downsample_4x4(images)
                output = model(x)
                pred = output.argmax(dim=1)
                correct += (pred == labels).sum().item()
                total += labels.size(0)

        acc = 100 * correct / total
        print(f"  Epoch {epoch+1}/10 — loss: {total_loss/len(train_loader):.4f}, accuracy: {acc:.1f}%")

    return model, test_loader

def train_synthetic():
    """Fallback if MNIST download fails."""
    print("Training on synthetic data...")
    model = SmallNet()
    optimizer = torch.optim.Adam(model.parameters(), lr=0.001)
    criterion = nn.CrossEntropyLoss()

    for epoch in range(50):
        x = torch.randn(256, INPUT_SIZE)
        labels = torch.randint(0, OUTPUT_SIZE, (256,))
        optimizer.zero_grad()
        loss = criterion(model(x), labels)
        loss.backward()
        optimizer.step()

    return model, None

# ── Quantization ─────────────────────────────────────────────────────────────

def float_to_q88(val):
    """Convert float to Q8.8 (signed 16-bit integer)."""
    q = int(round(val * 256))
    q = max(-32768, min(32767, q))
    return q & 0xFFFF  # unsigned representation

def q88_to_float(q):
    """Convert Q8.8 back to float."""
    if q >= 0x8000:
        q -= 0x10000
    return q / 256.0

def pack_two_q88(lo, hi):
    """Pack two Q8.8 values into one 32-bit word."""
    return (hi << 16) | lo

def quantize_and_verify(model):
    """Quantize weights/biases and verify error is small."""
    fc1_w = model.fc1.weight.detach().numpy()  # [HIDDEN, INPUT]
    fc1_b = model.fc1.bias.detach().numpy()     # [HIDDEN]
    fc2_w = model.fc2.weight.detach().numpy()  # [OUTPUT, HIDDEN]
    fc2_b = model.fc2.bias.detach().numpy()     # [OUTPUT]

    print(f"\nWeight ranges:")
    print(f"  fc1 weight: [{fc1_w.min():.3f}, {fc1_w.max():.3f}]")
    print(f"  fc1 bias:   [{fc1_b.min():.3f}, {fc1_b.max():.3f}]")
    print(f"  fc2 weight: [{fc2_w.min():.3f}, {fc2_w.max():.3f}]")
    print(f"  fc2 bias:   [{fc2_b.min():.3f}, {fc2_b.max():.3f}]")

    # Quantize
    fc1_w_q = np.vectorize(float_to_q88)(fc1_w)
    fc1_b_q = np.vectorize(float_to_q88)(fc1_b)
    fc2_w_q = np.vectorize(float_to_q88)(fc2_w)
    fc2_b_q = np.vectorize(float_to_q88)(fc2_b)

    # Verify quantization error
    fc1_w_recon = np.vectorize(q88_to_float)(fc1_w_q)
    max_err = np.max(np.abs(fc1_w - fc1_w_recon))
    print(f"\nMax quantization error (fc1 weights): {max_err:.6f}")

    return fc1_w_q, fc1_b_q, fc2_w_q, fc2_b_q

# ── Golden model ─────────────────────────────────────────────────────────────

def golden_inference_q88(input_q, w1_q, b1_q, w2_q, b2_q):
    """
    Run inference in Q8.8 integer arithmetic (matches hardware exactly).
    Returns (layer1_output, layer2_output, argmax_class).
    """
    input_len = len(input_q)
    hidden_size = w1_q.shape[0]
    output_size = w2_q.shape[0]

    # Layer 1: hidden = ReLU(W1 * input + b1)
    hidden = []
    for n in range(hidden_size):
        accum = 0
        for i in range(input_len):
            # Signed multiply
            a = input_q[i] if input_q[i] < 0x8000 else input_q[i] - 0x10000
            w = w1_q[n, i] if w1_q[n, i] < 0x8000 else w1_q[n, i] - 0x10000
            accum += a * w

        # Arithmetic right shift by 8, add bias
        shifted = accum >> 8 if accum >= 0 else -((-accum) >> 8)
        b = b1_q[n] if b1_q[n] < 0x8000 else b1_q[n] - 0x10000
        result = shifted + b

        # Clamp to 16-bit signed
        result = max(-32768, min(32767, result))
        # ReLU
        result = max(0, result)
        hidden.append(result & 0xFFFF)

    # Layer 2: output = W2 * hidden + b2 (no ReLU)
    output = []
    for n in range(output_size):
        accum = 0
        for i in range(hidden_size):
            a = hidden[i] if hidden[i] < 0x8000 else hidden[i] - 0x10000
            w = w2_q[n, i] if w2_q[n, i] < 0x8000 else w2_q[n, i] - 0x10000
            accum += a * w

        shifted = accum >> 8 if accum >= 0 else -((-accum) >> 8)
        b = b2_q[n] if b2_q[n] < 0x8000 else b2_q[n] - 0x10000
        result = shifted + b
        result = max(-32768, min(32767, result))
        # No ReLU on output layer
        output.append(result & 0xFFFF)

    # Argmax
    best_val = -99999
    best_idx = 0
    for i, v in enumerate(output):
        sv = v if v < 0x8000 else v - 0x10000
        if sv > best_val:
            best_val = sv
            best_idx = i

    return hidden, output, best_idx

# ── Export ────────────────────────────────────────────────────────────────────

def export_c_header(fc1_w_q, fc1_b_q, fc2_w_q, fc2_b_q, test_inputs, test_labels, golden_results, path):
    """Generate C header with packed Q8.8 weights and test data."""

    hidden_size = fc1_w_q.shape[0]
    input_size = fc1_w_q.shape[1]
    output_size = fc2_w_q.shape[0]

    with open(path, 'w') as f:
        f.write("// Auto-generated by python/train.py\n")
        f.write("// Network: %d → %d (ReLU) → %d\n" % (input_size, hidden_size, output_size))
        f.write("// Fixed-point: Q8.8\n\n")
        f.write("#ifndef NN_WEIGHTS_H\n#define NN_WEIGHTS_H\n\n")

        f.write("#define NN_INPUT_SIZE  %d\n" % input_size)
        f.write("#define NN_HIDDEN_SIZE %d\n" % hidden_size)
        f.write("#define NN_OUTPUT_SIZE %d\n\n" % output_size)

        # Layer 1 weights: packed as pairs [neuron][input_pair]
        # Weight layout: neuron N, input I → flat index = N*input_size + I
        f.write("// Layer 1 weights: [HIDDEN_SIZE * INPUT_SIZE / 2] packed words\n")
        f.write("// flat index = neuron * INPUT_SIZE + input_idx\n")
        f.write("static const unsigned int nn_fc1_weights[] = {\n")
        words = []
        for n in range(hidden_size):
            for i in range(0, input_size, 2):
                lo = fc1_w_q[n, i]
                hi = fc1_w_q[n, i+1] if i+1 < input_size else 0
                words.append(pack_two_q88(lo, hi))
        for i, w in enumerate(words):
            f.write("    0x%08X%s\n" % (w, "," if i < len(words)-1 else ""))
        f.write("};\n\n")

        # Layer 1 biases
        f.write("// Layer 1 biases: [HIDDEN_SIZE / 2] packed words\n")
        f.write("static const unsigned int nn_fc1_biases[] = {\n")
        words = []
        for i in range(0, hidden_size, 2):
            lo = fc1_b_q[i]
            hi = fc1_b_q[i+1] if i+1 < hidden_size else 0
            words.append(pack_two_q88(lo, hi))
        for i, w in enumerate(words):
            f.write("    0x%08X%s\n" % (w, "," if i < len(words)-1 else ""))
        f.write("};\n\n")

        # Layer 2 weights
        f.write("// Layer 2 weights: [OUTPUT_SIZE * HIDDEN_SIZE / 2] packed words\n")
        f.write("static const unsigned int nn_fc2_weights[] = {\n")
        words = []
        for n in range(output_size):
            for i in range(0, hidden_size, 2):
                lo = fc2_w_q[n, i]
                hi = fc2_w_q[n, i+1] if i+1 < hidden_size else 0
                words.append(pack_two_q88(lo, hi))
        for i, w in enumerate(words):
            f.write("    0x%08X%s\n" % (w, "," if i < len(words)-1 else ""))
        f.write("};\n\n")

        # Layer 2 biases
        f.write("// Layer 2 biases: [OUTPUT_SIZE / 2] packed words\n")
        f.write("static const unsigned int nn_fc2_biases[] = {\n")
        words = []
        for i in range(0, output_size, 2):
            lo = fc2_b_q[i]
            hi = fc2_b_q[i+1] if i+1 < output_size else 0
            words.append(pack_two_q88(lo, hi))
        for i, w in enumerate(words):
            f.write("    0x%08X%s\n" % (w, "," if i < len(words)-1 else ""))
        f.write("};\n\n")

        # Test images (first N)
        num_tests = len(test_inputs)
        f.write("#define NN_NUM_TESTS %d\n\n" % num_tests)
        f.write("// Test inputs (Q8.8, packed pairs)\n")
        f.write("static const unsigned int nn_test_inputs[][%d] = {\n" % (input_size // 2))
        for t in range(num_tests):
            f.write("    {")
            for i in range(0, input_size, 2):
                lo = test_inputs[t][i]
                hi = test_inputs[t][i+1] if i+1 < input_size else 0
                sep = ", " if i+2 < input_size else ""
                f.write("0x%08X%s" % (pack_two_q88(lo, hi), sep))
            f.write("},\n")
        f.write("};\n\n")

        # Expected labels and golden argmax
        f.write("// Expected labels\n")
        f.write("static const unsigned int nn_test_labels[] = {")
        f.write(", ".join(str(l) for l in test_labels))
        f.write("};\n\n")

        f.write("// Golden argmax from Q8.8 inference\n")
        f.write("static const unsigned int nn_golden_argmax[] = {")
        f.write(", ".join(str(r) for r in golden_results))
        f.write("};\n\n")

        f.write("#endif // NN_WEIGHTS_H\n")

    print(f"Exported C header to {path}")

# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_dir = os.path.dirname(script_dir)

    result = train()
    model = result[0]
    test_loader = result[1]

    # Quantize
    fc1_w_q, fc1_b_q, fc2_w_q, fc2_b_q = quantize_and_verify(model)

    # Get test images
    NUM_TESTS = 5
    if test_loader is not None:
        test_iter = iter(test_loader)
        images, labels = next(test_iter)
        x = downsample_4x4(images[:NUM_TESTS])
    else:
        # Synthetic fallback
        x = torch.randn(NUM_TESTS, INPUT_SIZE)
        labels = torch.randint(0, OUTPUT_SIZE, (NUM_TESTS,))

    # Quantize test inputs
    test_inputs_q = []
    for i in range(NUM_TESTS):
        inp = x[i].numpy()
        inp_q = [float_to_q88(v) for v in inp]
        test_inputs_q.append(inp_q)

    # Run golden model
    print("\nGolden model inference:")
    golden_results = []
    for i in range(NUM_TESTS):
        hidden, output, argmax = golden_inference_q88(
            test_inputs_q[i], fc1_w_q, fc1_b_q, fc2_w_q, fc2_b_q)
        golden_results.append(argmax)
        label = labels[i].item()

        # Convert output to signed for display
        out_signed = []
        for v in output:
            sv = v if v < 0x8000 else v - 0x10000
            out_signed.append(sv)

        print(f"  Test {i}: label={label}, predicted={argmax}, "
              f"outputs={[f'{v/256:.2f}' for v in out_signed]}")

    # Count matches
    correct = sum(1 for i in range(NUM_TESTS)
                  if golden_results[i] == labels[i].item())
    print(f"\nGolden accuracy: {correct}/{NUM_TESTS}")

    # Export
    header_path = os.path.join(project_dir, "fw", "nn_weights.h")
    export_c_header(fc1_w_q, fc1_b_q, fc2_w_q, fc2_b_q,
                    test_inputs_q, [l.item() for l in labels[:NUM_TESTS]],
                    golden_results, header_path)

    # Also save golden results for TB verification
    golden_path = os.path.join(script_dir, "golden.txt")
    with open(golden_path, 'w') as f:
        for i in range(NUM_TESTS):
            f.write(f"{labels[i].item()} {golden_results[i]}\n")
    print(f"Golden results saved to {golden_path}")

if __name__ == "__main__":
    main()
