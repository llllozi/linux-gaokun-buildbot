# EL2 EFI Payloads

This directory now only keeps the EFI-side files that are still deployed by the image build:

- `slbounceaa64.efi`
- `qebspilaa64.efi`
- `tcblaunch.exe`

When EL2 is enabled, CI installs:

- `slbounceaa64.efi` and `qebspilaa64.efi` into `EFI/systemd/drivers/`
- `tcblaunch.exe` into the ESP root

The old `bootaa64.efi` and its GNU-EFI build files were removed because the project now boots EL2 directly through `systemd-boot`.
