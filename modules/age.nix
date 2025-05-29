{
  config,
  options,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.age;

  isDarwin = lib.attrsets.hasAttrByPath ["environment" "darwinConfig"] options;

  ageBin = config.age.ageBin;

  users = config.users.users;

  mountCommand =
    if isDarwin
    then ''
      if ! diskutil info "${cfg.secretsMountPoint}" &> /dev/null; then
          num_sectors=1048576
          dev=$(hdiutil attach -nomount ram://"$num_sectors" | sed 's/[[:space:]]*$//')
          newfs_hfs -v agenix "$dev"
          mount -t hfs -o nobrowse,nodev,nosuid,-m=0751 "$dev" "${cfg.secretsMountPoint}"
      fi
    ''
    else ''
      grep -q "${cfg.secretsMountPoint} ramfs" /proc/mounts ||
        mount -t ramfs none "${cfg.secretsMountPoint}" -o nodev,nosuid,mode=0751
    '';
  newGeneration = ''
    _agenix_generation="$(basename "$(readlink ${cfg.secretsDir})" || echo 0)"
    (( ++_agenix_generation ))
    echo "[agenix] creating new generation in ${cfg.secretsMountPoint}/$_agenix_generation"
    mkdir -p "${cfg.secretsMountPoint}"
    chmod 0751 "${cfg.secretsMountPoint}"
    ${mountCommand}
    mkdir -p "${cfg.secretsMountPoint}/$_agenix_generation"
    chmod 0751 "${cfg.secretsMountPoint}/$_agenix_generation"
  '';

  chownGroup =
    if isDarwin
    then "admin"
    else "keys";

  chownMountPoint = ''
    chown :${chownGroup} "${cfg.secretsMountPoint}" "${cfg.secretsMountPoint}/$_agenix_generation"
  '';

  setTruePath = secretType: ''
    ${
      if secretType.symlink
      then ''
        _truePath="${cfg.secretsMountPoint}/$_agenix_generation/${secretType.name}"
      ''
      else ''
        _truePath="${secretType.path}"
      ''
    }
  '';

  installSecret = secretType: ''
    ${setTruePath secretType}
    echo "decrypting '${secretType.file}' to '$_truePath'..."
    TMP_FILE="$_truePath.tmp"

    # Check for YubiKey presence
    yubikey_missing=true
    ${pkgs.yubikey-personalization}/bin/ykinfo -v 1>/dev/null 2>&1
    if [ $? != "0" ]; then
        echo -n "waiting 10 seconds for YubiKey to appear..."
        for try in $(seq 10); do
            sleep 1
            ${pkgs.yubikey-personalization}/bin/ykinfo -v 1>/dev/null 2>&1
            if [ $? == "0" ]; then
                yubikey_missing=false
                break
            fi
            echo -n .
        done
        echo "ok"
    else
        yubikey_missing=false
    fi

    if [ "$yubikey_missing" == true ]; then
        echo "no YubiKey found, attempting decryption with available identities..."
    else
        echo "YubiKey detected, proceeding with decryption..."
    fi

    IDENTITIES=()
    for identity in ${toString cfg.identityPaths}; do
      test -r "$identity" || { echo "[agenix] WARNING: identity file $identity not readable"; continue; }
      test -s "$identity" || { echo "[agenix] WARNING: identity file $identity is empty"; continue; }
      IDENTITIES+=(-i)
      IDENTITIES+=("$identity")
    done

    mkdir -p "$(dirname "$_truePath")"
    [ "${secretType.path}" != "${cfg.secretsDir}/${secretType.name}" ] && mkdir -p "$(dirname "${secretType.path}")"
    (
      umask u=r,g=,o=
      test -f "${secretType.file}" || { echo '[agenix] ERROR: encrypted file ${secretType.file} does not exist!'; exit 1; }
      test -d "$(dirname "$TMP_FILE")" || { echo "[agenix] ERROR: directory $(dirname "$TMP_FILE") does not exist!"; exit 1; }
      # Retry decryption up to 3 times to handle potential YubiKey access issues
      for attempt in $(seq 3); do
        echo "[agenix] Attempting decryption (attempt $attempt of 3)..."
        if LANG=${config.i18n.defaultLocale or "C"} ${ageBin} --decrypt "''${IDENTITIES[@]}" -o "$TMP_FILE" "${secretType.file}" 2> decryption_error.log; then
          break
        else
          echo "[agenix] WARNING: decryption attempt $attempt failed: $(cat decryption_error.log)"
          if [ $attempt -lt 3 ]; then
            echo "Retrying in 2 seconds..."
            sleep 2
          else
            echo "[agenix] ERROR: decryption failed after 3 attempts, check YubiKey configuration or other identities"
            cat decryption_error.log
            exit 1
          fi
        fi
      done
      rm -f decryption_error.log
    )
    chmod ${secretType.mode} "$TMP_FILE"
    mv -f "$TMP_FILE" "$_truePath"

    ${optionalString secretType.symlink ''
      [ "${secretType.path}" != "${cfg.secretsDir}/${secretType.name}" ] && ln -sfT "${cfg.secretsDir}/${secretType.name}" "${secretType.path}"
    ''}
  '';

  testIdentities =
    map
    (path: ''
      test -f ${path} || echo '[agenix] WARNING: config.age.identityPaths entry ${path} not present!'
    '') cfg.identityPaths;

  cleanupAndLink = ''
    _agenix_generation="$(basename "$(readlink ${cfg.secretsDir})" || echo 0)"
    (( ++_agenix_generation ))
    echo "[agenix] symlinking new secrets to ${cfg.secretsDir} (generation $_agenix_generation)..."
    ln -sfT "${cfg.secretsMountPoint}/$_agenix_generation" ${cfg.secretsDir}

    (( _agenix_generation > 1 )) && {
    echo "[agenix] removing old secrets (generation $(( _agenix_generation - 1 )))..."
    rm -rf "${cfg.secretsMountPoint}/$(( _agenix_generation - 1 ))"
    }
  '';

  installSecrets = builtins.concatStringsSep "\n" (
    ["echo '[agenix] decrypting secrets...'"]
    ++ testIdentities
    ++ (map installSecret (builtins.attrValues cfg.secrets))
    ++ [cleanupAndLink]
  );

  chownSecret = secretType: ''
    ${setTruePath secretType}
    chown ${secretType.owner}:${secretType.group} "$_truePath"
  '';

  chownSecrets = builtins.concatStringsSep "\n" (
    ["echo '[agenix] chowning...'"]
    ++ [chownMountPoint]
    ++ (map chownSecret (builtins.attrValues cfg.secrets))
  );
in
{
  options.age = {
    secrets = mkOption {
      default = {};
      type = with types; attrsOf (submodule ({name, ...}: {
        options = {
          name = mkOption {
            type = types.str;
            default = name;
            description = ''
              Name of the file used in ${cfg.secretsDir}
            '';
          };
          file = mkOption {
            type = types.path;
            description = ''
              Age-encrypted file to decrypt.
            '';
          };
          path = mkOption {
            type = types.str;
            default = "${cfg.secretsDir}/${name}";
            description = ''
              Where to decrypt the file to.
              Warning: this file may be world-readable for a short amount of time before the chmod and chown happen!
            '';
          };
          mode = mkOption {
            type = types.str;
            default = "0400";
            description = ''
              Permissions mode of the decrypted file in octal.
            '';
          };
          owner = mkOption {
            type = types.str;
            default = "root";
            description = ''
              User of the file, defaults to root if not specified.
              If the system is not running yet, this should be the name of the user, not the uid.
            '';
          };
          group = mkOption {
            type = types.str;
            default = if isDarwin then "admin" else "root";
            description = ''
              Group of the file.
              If the system is not running yet, this should be the name of the group, not the gid.
            '';
          };
          symlink = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Whether to create a symlink at ${cfg.secretsDir}/${name} to the decrypted file.
            '';
          };
        };
      }));
      description = ''
        Secrets to decrypt.
      '';
    };
    secretsDir = mkOption {
      type = types.str;
      default = if isDarwin then "/private/var/lib/agenix" else "/run/agenix";
      description = ''
        Where to create generation symlink to decrypted secrets.
      '';
    };
    secretsMountPoint = mkOption {
      type = types.str;
      default = if isDarwin then "/Volumes/agenix" else "/run/agenix.d";
      description = ''
        Where to mount the ramfs and put the decrypted secrets before moving them to secretsDir.
      '';
    };
    identityPaths = mkOption {
      default = [];
      type = with types; listOf path;
      description = ''
        Paths to SSH private key files used as identities during decryption.
      '';
    };
    ageBin = mkOption {
      type = types.str;
      default = "${pkgs.rage}/bin/rage";
      description = ''
        Path to age/rage binary.
      '';
    };
  };

  config = {
    assertions = [
      {
        assertion = isDarwin || (builtins.length cfg.identityPaths > 0);
        message = ''
          You must set `age.identityPaths` to at least one SSH private key that can be used for decryption.
        '';
      }
    ] ++ (flip map (builtins.attrValues cfg.secrets) (secretType: {
      assertion = (builtins.stringLength secretType.owner) > 0 -> (builtins.hasAttr secretType.owner users);
      message = ''
        The user ${secretType.owner} for secret ${secretType.name} does not exist!
        If you are running this from a system that is not yet booted, you probably want to use the name of the user, not the uid.
      '';
    }));

    environment.etc = let
      secrets = filterAttrs (n: v: !v.symlink) cfg.secrets;
    in
      mapAttrs' (n: v: nameValuePair "agenix/${n}" {source = v.path; inherit (v) mode owner group;}) secrets;

    system.activationScripts.agenix = {
      text = ''
        ${newGeneration}
        ${installSecrets}
        ${chownSecrets}
      '';
      deps = if isDarwin then [] else ["users" "groups"];
    };
  };
}
