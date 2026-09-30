import torch

print("=== PyTorch Intel Arc XPU Verification ===")
print("PyTorch Version:", torch.__version__)
print("XPU available?:", torch.xpu.is_available())

if torch.xpu.is_available():
    print("Device count:  ", torch.xpu.device_count())
    print("Device name:   ", torch.xpu.get_device_name(0))
    
    print("\n--- Running Tensor Computation on XPU ---")
    x = torch.randn(2048, 2048, device="xpu")
    y = torch.randn(2048, 2048, device="xpu")
    z = torch.matmul(x, y)
    print("Matrix multiplication succeeded!")
    print("Result shape:", z.shape)
    print("Result sum:  ", z.sum().item())
    print("\n>>> ALL TESTS PASSED! Intel Arc GPU is fully functional in PyTorch! <<<")
else:
    print(">>> ERROR: XPU backend is NOT available. Check /dev/dxg and driver mount! <<<")
    exit(1)
