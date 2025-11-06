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

## 0.1.5 (2025-09-05)
- Fully optimize suspension time when applying hot upgrade

## 0.1.6 (2025-09-05)
- Add `mix fly_deploy.status`

## 0.1.7 (2025-09-05)
- Fix `mix fly_depoy.status` failing when more than one machine exists

## 0.1.8 (2025-09-06)
- Ensure consolidated protocols are upgraded

## 0.1.9 (2025-09-06)
- Support --build-arg to pass to `fly deploy`
