## 0.1.0 (2025-09-04)
- Initial release

## 0.1.1 (2025-09-04)
- Use BUCKET_NAME as default bucket (automatically set by `fly storage create`)

## 0.1.2 (2025-09-04)
- Fix LiveView process lookup, which was failing to send :phoenix_live_reload message, require a hard refresh to pick up upgraded changes to LiveViews

## 0.1.3 (2025-09-04)
- Instrument and log suspension time

## 0.1.4 (2025-09-04)
- Optimize suspension time by only copying parent OTP app files
that changed and precomputing changes
