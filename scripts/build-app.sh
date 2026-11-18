#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
scratch_dir="${PRESENCELOCK_SCRATCH_PATH:-/tmp/presencelock-release-build}"
build_jobs="${PRESENCELOCK_BUILD_JOBS:-1}"
output_dir="${project_dir}/build"
staging_root="${scratch_dir}/bundle"
app_dir="${staging_root}/PresenceLock.app"
info_plist="${project_dir}/Resources/Info.plist"
icon_path="${project_dir}/Resources/AppIcon.icns"
status_icon_names=("StatusIcon.png" "StatusIcon@2x.png")
version="$(plutil -extract CFBundleShortVersionString raw "${info_plist}")"
archive_path="${output_dir}/PresenceLock-${version}.zip"
checksum_path="${archive_path}.sha256"
verification_root="${scratch_dir}/verify-archive"

if [[ "${scratch_dir}" != /tmp/presencelock-* ]]; then
  echo "PRESENCELOCK_SCRATCH_PATH must be an explicit /tmp/presencelock-* path" >&2
  exit 1
fi

if [[ ! "${version}" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo "Invalid CFBundleShortVersionString: ${version}" >&2
  exit 1
fi

if [[ ! "${build_jobs}" =~ '^[1-9][0-9]*$' ]]; then
  echo "PRESENCELOCK_BUILD_JOBS must be a positive integer" >&2
  exit 1
fi

plutil -lint "${info_plist}" >/dev/null

mkdir -p "${scratch_dir}" "${output_dir}"
swift build \
  --package-path "${project_dir}" \
  --scratch-path "${scratch_dir}" \
  --configuration release \
  --jobs "${build_jobs}" \
  --product PresenceLock

binary_dir="$(swift build \
  --package-path "${project_dir}" \
  --scratch-path "${scratch_dir}" \
  --configuration release \
  --show-bin-path)"

if [[ "${app_dir}" != "${scratch_dir}/bundle/PresenceLock.app" ]]; then
  echo "Unexpected app output path" >&2
  exit 1
fi

rm -rf "${app_dir}"
mkdir -p "${app_dir}/Contents/MacOS" "${app_dir}/Contents/Resources"
cp "${binary_dir}/PresenceLock" "${app_dir}/Contents/MacOS/PresenceLock"
cp "${info_plist}" "${app_dir}/Contents/Info.plist"
if [[ -f "${icon_path}" ]]; then
  cp "${icon_path}" "${app_dir}/Contents/Resources/AppIcon.icns"
else
  echo "Warning: Resources/AppIcon.icns is missing; the build will use a generic app icon" >&2
fi
for status_icon_name in "${status_icon_names[@]}"; do
  status_icon_path="${project_dir}/Resources/${status_icon_name}"
  if [[ -f "${status_icon_path}" ]]; then
    cp "${status_icon_path}" "${app_dir}/Contents/Resources/${status_icon_name}"
  fi
done
for localization in "${project_dir}/Resources/"*.lproj; do
  plutil -lint "${localization}"/*.strings >/dev/null
  cp -R "${localization}" "${app_dir}/Contents/Resources/"
done
chmod 755 "${app_dir}/Contents/MacOS/PresenceLock"

bundle_id="$(plutil -extract CFBundleIdentifier raw "${app_dir}/Contents/Info.plist")"
bundle_version="$(plutil -extract CFBundleShortVersionString raw "${app_dir}/Contents/Info.plist")"
[[ "${bundle_id}" == "local.aszzi.presencelock" ]]
[[ "${bundle_version}" == "${version}" ]]
[[ -x "${app_dir}/Contents/MacOS/PresenceLock" ]]

xattr -cr "${app_dir}"
codesign --force --sign - --timestamp=none "${app_dir}"
codesign --verify --deep --strict "${app_dir}"

rm -f "${archive_path}" "${checksum_path}"
ditto --norsrc -c -k --keepParent "${app_dir}" "${archive_path}"
unzip -tq "${archive_path}" >/dev/null

rm -rf "${verification_root}"
mkdir -p "${verification_root}"
ditto -x -k "${archive_path}" "${verification_root}"
codesign --verify --deep --strict "${verification_root}/PresenceLock.app"

verified_info="${verification_root}/PresenceLock.app/Contents/Info.plist"
verified_version="$(plutil -extract CFBundleShortVersionString raw "${verified_info}")"
verified_bundle_id="$(plutil -extract CFBundleIdentifier raw "${verified_info}")"
[[ "${verified_version}" == "${version}" ]]
[[ "${verified_bundle_id}" == "${bundle_id}" ]]
[[ -x "${verification_root}/PresenceLock.app/Contents/MacOS/PresenceLock" ]]
if [[ -f "${icon_path}" ]]; then
  [[ -f "${verification_root}/PresenceLock.app/Contents/Resources/AppIcon.icns" ]]
fi
for status_icon_name in "${status_icon_names[@]}"; do
  status_icon_path="${project_dir}/Resources/${status_icon_name}"
  if [[ -f "${status_icon_path}" ]]; then
    [[ -f "${verification_root}/PresenceLock.app/Contents/Resources/${status_icon_name}" ]]
  fi
done
for localization in "${project_dir}/Resources/"*.lproj; do
  diff -rq "${localization}" "${verification_root}/PresenceLock.app/Contents/Resources/${localization:t}"
done

archive_name="${archive_path:t}"
(cd "${output_dir}" && shasum -a 256 "${archive_name}" > "${archive_name}.sha256")
(cd "${output_dir}" && shasum -a 256 -c "${archive_name}.sha256" >/dev/null)

echo "Built ${archive_path}"
echo "SHA-256 ${checksum_path}"
