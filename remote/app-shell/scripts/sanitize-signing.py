#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
dsh-mobile 鸿蒙工程签名脱敏辅助工具。

功能：
  python scripts/sanitize-signing.py status   -- 查看当前 build-profile.json5 签名状态与备份状态
  python scripts/sanitize-signing.py backup   -- 仅备份当前签名版 build-profile.json5（不改动原文件）
  python scripts/sanitize-signing.py strip    -- 先自动备份，再剥离 products.signingConfig 与 signingConfigs
  python scripts/sanitize-signing.py restore  -- 从备份恢复签名版 build-profile.json5

默认备份位置放在 .hvigor/signing-backup.json5（robocopy 同步发布目录时默认排除 .hvigor，
避免把本地证书路径与密文口令带入开源仓库）。也可通过 --file 与 --backup 指定目标路径。
"""

import argparse
import os
import re
import shutil
import sys


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
APP_SHELL_DIR = os.path.dirname(SCRIPT_DIR)
DEFAULT_PROFILE = os.path.join(APP_SHELL_DIR, "build-profile.json5")
DEFAULT_BACKUP = os.path.join(APP_SHELL_DIR, ".hvigor", "signing-backup.json5")


def read_utf8(path: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def write_utf8(path: str, content: str) -> None:
    parent = os.path.dirname(os.path.abspath(path))
    if parent and not os.path.exists(parent):
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(content)


def has_signing(content: str) -> bool:
    if re.search(r'"signingConfig"\s*:\s*"[^"]+"', content):
        return True
    m = re.search(r'"signingConfigs"\s*:\s*\[(.*?)\]', content, flags=re.S)
    if m and m.group(1).strip() != "":
        return True
    return False


def strip_signing_text(content: str) -> str:
    # 移除 products 项内的 "signingConfig": "...", 行
    out = re.sub(r'^[ \t]*"signingConfig"\s*:\s*"[^"]+"\s*,?[ \t]*\r?\n', "", content, flags=re.M)
    # 将 signingConfigs 数组清空为 []（兼容嵌套 material 花括号）
    pattern = re.compile(
        r'("signingConfigs"\s*:\s*\[)(?:[^{}\[\]]|\{(?:[^{}]|\{[^{}]*\})*\})*(\])',
        flags=re.S,
    )
    out, count = pattern.subn(r"\1\2", out, count=1)
    if count == 0:
        raise RuntimeError("未在目标文件中找到 signingConfigs 字段")
    return out


def cmd_status(profile_path: str, backup_path: str) -> int:
    if not os.path.exists(profile_path):
        print(f"[ERROR] 找不到配置文件: {profile_path}", file=sys.stderr)
        return 1
    content = read_utf8(profile_path)
    signed = has_signing(content)
    bak_exists = os.path.exists(backup_path)
    print(f"profile : {profile_path}")
    print(f"state   : {'signed (含本地签名配置)' if signed else 'sanitized (已脱敏)'}")
    print(f"backup  : {backup_path} ({'exists' if bak_exists else 'none'})")
    return 0


def cmd_backup(profile_path: str, backup_path: str) -> int:
    if not os.path.exists(profile_path):
        print(f"[ERROR] 找不到配置文件: {profile_path}", file=sys.stderr)
        return 1
    content = read_utf8(profile_path)
    if not has_signing(content):
        print("[WARN] 当前 build-profile.json5 已是脱敏状态，跳过覆盖备份以免冲掉真实签名备份。")
        return 0
    parent = os.path.dirname(os.path.abspath(backup_path))
    if parent and not os.path.exists(parent):
        os.makedirs(parent, exist_ok=True)
    shutil.copy2(profile_path, backup_path)
    print(f"[OK] 已备份签名配置 -> {backup_path}")
    return 0


def cmd_strip(profile_path: str, backup_path: str, no_backup: bool) -> int:
    if not os.path.exists(profile_path):
        print(f"[ERROR] 找不到配置文件: {profile_path}", file=sys.stderr)
        return 1
    content = read_utf8(profile_path)
    if has_signing(content) and not no_backup:
        rc = cmd_backup(profile_path, backup_path)
        if rc != 0:
            return rc
    sanitized = strip_signing_text(content)
    if has_signing(sanitized):
        print("[ERROR] 脱敏后仍检测到残留签名配置，已中止写入。", file=sys.stderr)
        return 2
    write_utf8(profile_path, sanitized)
    print(f"[OK] 已剥离签名配置 -> {profile_path}")
    return 0


def cmd_restore(profile_path: str, backup_path: str) -> int:
    if not os.path.exists(backup_path):
        print(f"[ERROR] 找不到签名备份文件: {backup_path}", file=sys.stderr)
        return 1
    backup_content = read_utf8(backup_path)
    if not has_signing(backup_content):
        print(f"[ERROR] 备份文件不含有效签名配置: {backup_path}", file=sys.stderr)
        return 2
    write_utf8(profile_path, backup_content)
    print(f"[OK] 已恢复签名配置 -> {profile_path}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="备份/剥离/恢复鸿蒙 build-profile.json5 签名配置")
    parser.add_argument(
        "action",
        nargs="?",
        default="status",
        choices=["status", "backup", "strip", "sanitize", "restore"],
        help="执行动作：status(默认) / backup / strip(或 sanitize) / restore",
    )
    parser.add_argument("--file", default=DEFAULT_PROFILE, help="目标 build-profile.json5 路径")
    parser.add_argument("--backup", default=DEFAULT_BACKUP, help="备份文件路径")
    parser.add_argument("--no-backup", action="store_true", help="strip 时跳过备份（适用于发布克隆副本）")
    args = parser.parse_args()

    if args.action == "status":
        return cmd_status(args.file, args.backup)
    if args.action == "backup":
        return cmd_backup(args.file, args.backup)
    if args.action in ("strip", "sanitize"):
        return cmd_strip(args.file, args.backup, args.no_backup)
    if args.action == "restore":
        return cmd_restore(args.file, args.backup)
    return 1


if __name__ == "__main__":
    sys.exit(main())
