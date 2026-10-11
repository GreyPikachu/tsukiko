import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/platform/os_windows.dart';

void main() {
  const intel =
      'ggml_vulkan: 0 = Intel(R) Arc(TM) Graphics (Intel Corporation) | uma: 1 | fp16: 1';
  const nvidia =
      'ggml_vulkan: 1 = NVIDIA GeForce RTX 4060 Laptop GPU (NVIDIA) | uma: 0 | fp16: 1';

  test('встроенная первой, дискретная второй — берём дискретную', () {
    expect(discreteVulkanDevice('ggml_vulkan: Found 2 Vulkan devices:\n$intel\n$nvidia'), 1);
  });

  test('одна видеокарта — подсказка не нужна', () {
    expect(discreteVulkanDevice(intel), isNull);
    expect(discreteVulkanDevice(nvidia.replaceFirst(': 1 =', ': 0 =')), isNull);
  });

  test('две дискретные — оставляем ggml самому', () {
    expect(
      discreteVulkanDevice(
          '${nvidia.replaceFirst(': 1 =', ': 0 =')}\n$nvidia'.replaceAll('uma: 1', 'uma: 0')),
      isNull,
    );
  });

  test('Dozen поверх D3D12 не выигрывает у родного драйвера', () {
    const dozen =
        'ggml_vulkan: 1 = Microsoft Direct3D12 (NVIDIA GeForce RTX 4060) (Dozen) | uma: 0 | fp16: 1';
    final native = nvidia.replaceFirst(': 1 =', ': 2 =');
    expect(discreteVulkanDevice('$intel\n$dozen\n$native'), 2);
  });

  test('пустой вывод — ничего не задаём', () {
    expect(discreteVulkanDevice(''), isNull);
  });
}
