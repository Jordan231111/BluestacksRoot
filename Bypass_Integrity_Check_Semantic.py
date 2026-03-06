from __future__ import annotations

import argparse
import ctypes
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

try:
    import pefile
except ImportError as exc:  # pragma: no cover - runtime dependency
    raise SystemExit(
        "Missing dependency: pefile. Install it with `pip install pefile`."
    ) from exc

try:
    from capstone import CS_ARCH_X86, CS_MODE_64, Cs
    from capstone.x86_const import (
        X86_OP_IMM,
        X86_OP_MEM,
        X86_OP_REG,
        X86_REG_BL,
        X86_REG_EAX,
        X86_REG_R8D,
        X86_REG_RIP,
    )
except ImportError as exc:  # pragma: no cover - runtime dependency
    raise SystemExit(
        "Missing dependency: capstone. Install it with `pip install capstone`."
    ) from exc


BLOCK_FAILURE_TEXT = "Failed to verify the file %s at block %u"
DISK_OK_TEXT = "Verified the disk integrity!"
DISK_FAIL_TEXT = "Failed to verify the disk integrity!"
WARMUP_TEXT = "In warmup mode: Stopping player."
TAMPER_TEXT = "Shutting down: disk file have been illegally tampered with!"


@dataclass(frozen=True)
class FunctionRange:
    begin_rva: int
    end_rva: int
    raw_begin: int
    raw_end: int


@dataclass
class InstructionView:
    raw: int
    address: int
    size: int
    mnemonic: str
    op_str: str
    bytes_: bytes
    insn: object


@dataclass
class XrefHit:
    text: str
    function: FunctionRange
    instruction: InstructionView


@dataclass
class PlannedPatch:
    name: str
    raw: int
    original: bytes
    patched: bytes
    reason: str
    optional: bool = False


class SemanticPatcher:
    def __init__(self, source_path: Path) -> None:
        self.source_path = source_path
        self.image = source_path.read_bytes()
        self.pe = pefile.PE(str(source_path), fast_load=False)
        self.pe.parse_data_directories(
            directories=[pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_EXCEPTION"]]
        )
        self.base = self.pe.OPTIONAL_HEADER.ImageBase
        self.text_section = self._find_text_section()
        self.text_rva = self.text_section.VirtualAddress
        self.text_end_rva = self.text_rva + max(
            self.text_section.Misc_VirtualSize, self.text_section.SizeOfRawData
        )
        self.text_raw = self.text_section.PointerToRawData
        self._functions = self._load_function_ranges()
        self._disasm_cache: Dict[Tuple[int, int], List[InstructionView]] = {}

    def _find_text_section(self):
        for section in self.pe.sections:
            if section.Name.rstrip(b"\x00") == b".text":
                return section
        raise RuntimeError("Could not find .text section in HD-Player.exe.")

    def _load_function_ranges(self) -> List[FunctionRange]:
        ranges: List[FunctionRange] = []
        seen = set()
        for entry in getattr(self.pe, "DIRECTORY_ENTRY_EXCEPTION", []):
            begin = entry.struct.BeginAddress
            end = entry.struct.EndAddress
            if not (self.text_rva <= begin < end <= self.text_end_rva):
                continue
            if (begin, end) in seen:
                continue
            seen.add((begin, end))
            raw_begin = self.text_raw + (begin - self.text_rva)
            raw_end = self.text_raw + (end - self.text_rva)
            ranges.append(FunctionRange(begin, end, raw_begin, raw_end))
        if not ranges:
            raise RuntimeError("Could not read x64 function ranges from exception data.")
        return ranges

    def _disassemble_function(self, func: FunctionRange) -> List[InstructionView]:
        key = (func.begin_rva, func.end_rva)
        if key in self._disasm_cache:
            return self._disasm_cache[key]

        code = self.image[func.raw_begin : func.raw_end]
        md = Cs(CS_ARCH_X86, CS_MODE_64)
        md.detail = True
        start_address = self.base + func.begin_rva
        insns: List[InstructionView] = []
        for insn in md.disasm(code, start_address):
            raw = func.raw_begin + (insn.address - start_address)
            insns.append(
                InstructionView(
                    raw=raw,
                    address=insn.address,
                    size=insn.size,
                    mnemonic=insn.mnemonic,
                    op_str=insn.op_str,
                    bytes_=bytes(insn.bytes),
                    insn=insn,
                )
            )
        self._disasm_cache[key] = insns
        return insns

    def _find_string_raw(self, text: str) -> int:
        raw = self.image.find(text.encode("utf-8") + b"\x00")
        if raw == -1:
            raise RuntimeError(f"Could not find required string: {text!r}")
        return raw

    def _raw_to_va(self, raw: int) -> int:
        return self.base + self.pe.get_rva_from_offset(raw)

    def _rip_target(self, ins: InstructionView) -> Optional[int]:
        for operand in ins.insn.operands:
            if operand.type == X86_OP_MEM and operand.mem.base == X86_REG_RIP:
                return ins.address + ins.size + operand.mem.disp
        return None

    def find_string_xrefs(self, texts: Sequence[str]) -> Dict[str, XrefHit]:
        target_map = {self._raw_to_va(self._find_string_raw(text)): text for text in texts}
        hits: Dict[str, List[XrefHit]] = {text: [] for text in texts}

        for func in self._functions:
            insns = self._disassemble_function(func)
            for ins in insns:
                target = self._rip_target(ins)
                if target is None or target not in target_map:
                    continue
                hits[target_map[target]].append(XrefHit(target_map[target], func, ins))

        resolved: Dict[str, XrefHit] = {}
        for text, text_hits in hits.items():
            if len(text_hits) != 1:
                raise RuntimeError(
                    f"Expected exactly one code reference to {text!r}, found {len(text_hits)}."
                )
            resolved[text] = text_hits[0]
        return resolved


def is_admin() -> bool:
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


def relaunch_as_admin() -> None:
    params = subprocess.list2cmdline(sys.argv)
    result = ctypes.windll.shell32.ShellExecuteW(
        None, "runas", sys.executable, params, None, 1
    )
    if result <= 32:
        raise SystemExit("Failed to elevate this patcher with Administrator rights.")
    raise SystemExit(0)


def previous_non_nop(insns: Sequence[InstructionView], start_idx: int) -> Optional[int]:
    idx = start_idx
    while idx >= 0:
        if insns[idx].mnemonic != "nop":
            return idx
        idx -= 1
    return None


def has_reg_imm_before(
    insns: Sequence[InstructionView], start_idx: int, reg_id: int, imm_value: int, max_steps: int
) -> bool:
    steps = 0
    idx = start_idx - 1
    while idx >= 0 and steps < max_steps:
        ins = insns[idx]
        steps += 1
        if ins.mnemonic != "mov" or len(ins.insn.operands) != 2:
            idx -= 1
            continue
        dst, src = ins.insn.operands
        if dst.type == X86_OP_REG and src.type == X86_OP_IMM:
            if dst.reg == reg_id and src.imm == imm_value:
                return True
        idx -= 1
    return False


def is_test_same_reg(ins: InstructionView, reg_id: int) -> bool:
    if ins.mnemonic != "test" or len(ins.insn.operands) != 2:
        return False
    left, right = ins.insn.operands
    return (
        left.type == X86_OP_REG
        and right.type == X86_OP_REG
        and left.reg == reg_id
        and right.reg == reg_id
    )


def is_cmp_byte_mem_zero(ins: InstructionView, disp: int) -> bool:
    if ins.mnemonic != "cmp" or len(ins.insn.operands) != 2:
        return False
    left, right = ins.insn.operands
    return (
        left.type == X86_OP_MEM
        and right.type == X86_OP_IMM
        and left.mem.disp == disp
        and right.imm == 0
    )


def is_conditional_jump(ins: InstructionView, mnemonics: Sequence[str]) -> bool:
    return ins.mnemonic in mnemonics


def jump_to_unconditional(ins: InstructionView) -> bytes:
    data = bytearray(ins.bytes_)
    if len(data) == 2 and 0x70 <= data[0] <= 0x7F:
        data[0] = 0xEB
        return bytes(data)
    if len(data) == 6 and data[0] == 0x0F and 0x80 <= data[1] <= 0x8F:
        data[0] = 0x90
        data[1] = 0xE9
        return bytes(data)
    raise RuntimeError(
        f"Unsupported conditional jump encoding at 0x{ins.raw:X}: {ins.bytes_.hex(' ')}"
    )


def locate_patch1(insns: Sequence[InstructionView], failure_xref_raw: int) -> InstructionView:
    xref_idx = next(i for i, ins in enumerate(insns) if ins.raw == failure_xref_raw)
    candidates: List[Tuple[int, InstructionView]] = []

    for idx in range(xref_idx - 1, -1, -1):
        if failure_xref_raw - insns[idx].raw > 0x90:
            break
        test_ins = insns[idx]
        if idx + 1 >= len(insns):
            continue
        jcc_ins = insns[idx + 1]
        if not is_test_same_reg(test_ins, X86_REG_EAX):
            continue
        if not is_conditional_jump(jcc_ins, ("je", "jz")):
            continue
        call_idx = previous_non_nop(insns, idx - 1)
        if call_idx is None or insns[call_idx].mnemonic != "call":
            continue

        score = 0
        call_operand = insns[call_idx].insn.operands[0]
        if call_operand.type == X86_OP_IMM:
            score += 50
        if has_reg_imm_before(insns, call_idx, X86_REG_R8D, 0x20, 8):
            score += 100
        candidates.append((score, jcc_ins))

    if not candidates:
        raise RuntimeError("Could not locate Patch 1 from block-verification semantics.")
    candidates.sort(key=lambda item: item[0], reverse=True)
    return candidates[0][1]


def locate_patch2(insns: Sequence[InstructionView], tamper_xref_raw: int) -> InstructionView:
    xref_idx = next(i for i, ins in enumerate(insns) if ins.raw == tamper_xref_raw)
    for idx in range(xref_idx - 1, -1, -1):
        if tamper_xref_raw - insns[idx].raw > 0x30:
            break
        test_ins = insns[idx]
        if idx + 1 >= len(insns):
            continue
        jcc_ins = insns[idx + 1]
        if not is_test_same_reg(test_ins, X86_REG_EAX):
            continue
        if not is_conditional_jump(jcc_ins, ("je", "jz")):
            continue
        call_idx = previous_non_nop(insns, idx - 1)
        if call_idx is not None and insns[call_idx].mnemonic == "call":
            return jcc_ins
    raise RuntimeError("Could not locate Patch 2 near the tamper shutdown message.")


def locate_patch3(insns: Sequence[InstructionView], warmup_xref_raw: int) -> InstructionView:
    xref_idx = next(i for i, ins in enumerate(insns) if ins.raw == warmup_xref_raw)
    for idx in range(xref_idx - 1, -1, -1):
        if warmup_xref_raw - insns[idx].raw > 0x60:
            break
        cmp_ins = insns[idx]
        if idx + 1 >= len(insns):
            continue
        jcc_ins = insns[idx + 1]
        if not is_cmp_byte_mem_zero(cmp_ins, 0x78):
            continue
        if is_conditional_jump(jcc_ins, ("je", "jz")):
            return jcc_ins
    raise RuntimeError("Could not locate Patch 3 from the warmup-stop path.")


def locate_patch4(insns: Sequence[InstructionView], tamper_xref_raw: int) -> InstructionView:
    xref_idx = next(i for i, ins in enumerate(insns) if ins.raw == tamper_xref_raw)
    for idx in range(xref_idx - 1, -1, -1):
        if tamper_xref_raw - insns[idx].raw > 0x40:
            break
        test_ins = insns[idx]
        if idx + 1 >= len(insns):
            continue
        jcc_ins = insns[idx + 1]
        if is_test_same_reg(test_ins, X86_REG_BL) and is_conditional_jump(
            jcc_ins, ("jne", "jnz")
        ):
            return jcc_ins
    raise RuntimeError("Could not locate Patch 4 from the tamper fallback path.")


def plan_patches(patcher: SemanticPatcher) -> List[PlannedPatch]:
    xrefs = patcher.find_string_xrefs(
        [
            BLOCK_FAILURE_TEXT,
            DISK_OK_TEXT,
            DISK_FAIL_TEXT,
            WARMUP_TEXT,
            TAMPER_TEXT,
        ]
    )

    security_func = xrefs[BLOCK_FAILURE_TEXT].function
    disk_functions = {
        xrefs[DISK_OK_TEXT].function,
        xrefs[DISK_FAIL_TEXT].function,
        xrefs[WARMUP_TEXT].function,
        xrefs[TAMPER_TEXT].function,
    }
    if len(disk_functions) != 1:
        raise RuntimeError("Disk integrity strings no longer live in a single function.")
    disk_func = next(iter(disk_functions))

    security_insns = patcher._disassemble_function(security_func)
    disk_insns = patcher._disassemble_function(disk_func)

    patch_sites = [
        (
            "Patch 1",
            locate_patch1(security_insns, xrefs[BLOCK_FAILURE_TEXT].instruction.raw),
            "Force per-block verification failures down the success path.",
            False,
        ),
        (
            "Patch 2",
            locate_patch2(disk_insns, xrefs[TAMPER_TEXT].instruction.raw),
            "Skip the tamper-report path that follows the final disk check.",
            True,
        ),
        (
            "Patch 3",
            locate_patch3(disk_insns, xrefs[WARMUP_TEXT].instruction.raw),
            "Bypass the primary warmup/stop gate in the disk-check thread.",
            False,
        ),
        (
            "Patch 4",
            locate_patch4(disk_insns, xrefs[TAMPER_TEXT].instruction.raw),
            "Bypass the fallback shutdown gate in the disk-check thread.",
            False,
        ),
    ]

    plans: List[PlannedPatch] = []
    for name, ins, reason, optional in patch_sites:
        plans.append(
            PlannedPatch(
                name=name,
                raw=ins.raw,
                original=ins.bytes_,
                patched=jump_to_unconditional(ins),
                reason=reason,
                optional=optional,
            )
        )
    return plans


def stop_hd_player() -> None:
    subprocess.run(
        ["taskkill", "/F", "/IM", "HD-Player.exe"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def snapshot_path(exe_path: Path) -> Path:
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    return exe_path.with_name(f"{exe_path.name}.pre_semantic_patch_{stamp}")


def apply_patches_to_image(image: bytearray, plans: Sequence[PlannedPatch]) -> None:
    for plan in plans:
        current = bytes(image[plan.raw : plan.raw + len(plan.original)])
        if current != plan.original:
            raise RuntimeError(
                f"{plan.name} expected {plan.original.hex(' ')} at 0x{plan.raw:X}, "
                f"found {current.hex(' ')}."
            )
        image[plan.raw : plan.raw + len(plan.patched)] = plan.patched


def verify_output(output_path: Path, plans: Sequence[PlannedPatch]) -> None:
    output = output_path.read_bytes()
    for plan in plans:
        actual = output[plan.raw : plan.raw + len(plan.patched)]
        if actual != plan.patched:
            raise RuntimeError(
                f"Verification failed for {plan.name} at 0x{plan.raw:X}: "
                f"expected {plan.patched.hex(' ')}, found {actual.hex(' ')}."
            )


def write_output(exe_path: Path, patched_image: bytes) -> Optional[Path]:
    current_image = exe_path.read_bytes() if exe_path.exists() else b""
    if current_image == patched_image:
        return None

    snap = snapshot_path(exe_path)
    if exe_path.exists():
        shutil.copy2(exe_path, snap)

    temp_path = exe_path.with_name(exe_path.name + ".semantic_tmp")
    temp_path.write_bytes(patched_image)
    os.replace(temp_path, exe_path)
    return snap


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Semantic BlueStacks HD-Player integrity patcher."
    )
    parser.add_argument(
        "--exe",
        default=r"C:\Program Files\BlueStacks_nxt\HD-Player.exe",
        help="Path to HD-Player.exe",
    )
    parser.add_argument(
        "--backup",
        default=r"C:\Program Files\BlueStacks_nxt\HD-Player.exe.original",
        help="Path to the untouched HD-Player.exe.original backup",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Locate patch sites and print the plan without writing the executable.",
    )
    parser.add_argument(
        "--restore",
        action="store_true",
        help="Restore HD-Player.exe from the .original backup and exit.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    exe_path = Path(args.exe)
    backup_path = Path(args.backup)

    if not backup_path.exists():
        raise SystemExit(f"Backup executable not found: {backup_path}")

    if args.restore:
        if args.dry_run:
            print(f"[+] Dry run: would restore {exe_path} from {backup_path}")
            return 0
        if not args.dry_run and not is_admin():
            relaunch_as_admin()
        stop_hd_player()
        shutil.copy2(backup_path, exe_path)
        print(f"[+] Restored {exe_path} from {backup_path}")
        return 0

    patcher = SemanticPatcher(backup_path)
    plans = plan_patches(patcher)
    patched_image = bytearray(patcher.image)
    apply_patches_to_image(patched_image, plans)

    print("Semantic patch plan:")
    for plan in plans:
        suffix = " (optional)" if plan.optional else ""
        print(
            f"  {plan.name}{suffix}: 0x{plan.raw:X}  "
            f"{plan.original.hex(' ')} -> {plan.patched.hex(' ')}"
        )
        print(f"    {plan.reason}")

    if args.dry_run:
        print("[+] Dry run complete. No files were modified.")
        return 0

    if not is_admin():
        relaunch_as_admin()

    stop_hd_player()
    snap = write_output(exe_path, bytes(patched_image))
    if snap is None:
        print("[+] HD-Player.exe already matches the semantic patch output.")
        return 0

    verify_output(exe_path, plans)
    print(f"[+] Wrote patched executable: {exe_path}")
    print(f"[+] Snapshot of previous executable: {snap}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
