import difflib
import os
import re
import shutil
import tkinter as tk
from datetime import datetime
from pathlib import Path
from tkinter import filedialog, messagebox, scrolledtext, ttk
import xml.etree.ElementTree as ET

# DITAで使用される標準名前空間のプレフィックス維持
ET.register_namespace("ditaarch", "http://dita.oasis-open.org/architecture/2005/")
ET.register_namespace("xsi", "http://www.w3.org/2001/XMLSchema-instance")

# <prolog> を挿入すべき位置の基準となる後続要素（DITA DTD構造準拠）
BODY_AND_AFTER_TAGS = {
    "body",
    "taskbody",
    "conbody",
    "refbody",
    "glossbody",
    "related-links",
    "topic",
    "task",
    "concept",
    "reference",
}

# 比較の最小単位として扱うブロック・リーフ要素
LEAF_COMPARE_TAGS = {
    "title",
    "navtitle",
    "searchtitle",
    "shortdesc",
    "p",
    "li",
    "cmd",
    "info",
    "stepresult",
    "stepxmp",
    "choicetable",
    "choption",
    "chdesc",
    "entry",
    "dt",
    "dd",
    "note",
    "codeblock",
    "pre",
    "lq",
    "fig",
    "alt",
    "term",
    "keyword",
}


def extract_xml_header(raw_text: str) -> str:
    """元のDITAファイルから <?xml ...?> と <!DOCTYPE ...> のヘッダ部分を抽出する"""
    pattern = r"^(\s*(?:<\?xml[^?]*\?>\s*)?(?:<!DOCTYPE(?:\[[^\]]*\]|[^>])*>\s*)?)"
    match = re.match(pattern, raw_text, flags=re.DOTALL | re.IGNORECASE)
    if match and match.group(1).strip():
        return match.group(1)
    return '<?xml version="1.0" encoding="UTF-8"?>\n'


def normalize_text(elem: ET.Element) -> str:
    """要素配下の全テキストを正規化して取得（改行・連続空白の揺れを吸収）"""
    raw = "".join(elem.itertext())
    return re.sub(r"\s+", " ", raw).strip()


def truncate_text(text: str, max_len: int = 45) -> str:
    """履歴表示用に長い文字列を省略する"""
    if not text:
        return "(テキストなし)"
    return text if len(text) <= max_len else text[:max_len] + "..."


def element_signature(elem: ET.Element) -> str:
    """要素の比較用シグネチャ（タグ名・主要属性・正規化テキスト）を生成"""
    # 履歴用属性自体は比較対象から除外
    attrs = sorted(
        (k, v) for k, v in elem.attrib.items() if k not in {"rev", "status"}
    )
    attr_str = ",".join(f"{k}={v}" for k, v in attrs)
    text_str = normalize_text(elem)
    child_tags = ",".join(
        c.tag for c in elem if isinstance(c.tag, str)
    )
    return f"{elem.tag}[{attr_str}]|{text_str}|({child_tags})"


def is_atomic_element(elem: ET.Element) -> bool:
    """子要素単位で再帰比較するか、その要素単位で差分判定するかを返す"""
    if elem.tag in LEAF_COMPARE_TAGS:
        return True
    # 文字列タグの子要素を持たない場合はリーフ要素
    child_elems = [c for c in elem if isinstance(c.tag, str)]
    return len(child_elems) == 0


def compare_and_mark_elements(
    before_elem: ET.Element,
    after_elem: ET.Element,
    author: str,
    timestamp: str,
    changes_log: list[str],
) -> None:
    """2つのXML要素を再帰的に比較し、変更箇所へ属性とコメントを付与する"""
    rev_value = f"{timestamp} ({author})"

    # リーフ/ブロック単位の要素比較
    if is_atomic_element(before_elem) or is_atomic_element(after_elem):
        if element_signature(before_elem) != element_signature(after_elem):
            old_txt = truncate_text(normalize_text(before_elem))
            new_txt = truncate_text(normalize_text(after_elem))
            after_elem.set("status", "changed")
            after_elem.set("rev", rev_value)
            changes_log.append(f"[{after_elem.tag}] 「{old_txt}」 → 「{new_txt}」")
        return

    # コンテナ要素の場合は子要素リストを SequenceMatcher で比較
    b_children = [c for c in list(before_elem) if isinstance(c.tag, str)]
    a_children = [c for c in list(after_elem) if isinstance(c.tag, str)]

    b_sigs = [element_signature(c) for c in b_children]
    a_sigs = [element_signature(c) for c in a_children]

    matcher = difflib.SequenceMatcher(None, b_sigs, a_sigs, autojunk=False)

    # 挿入するコメントの記録: (対象after子要素のオブジェクト, コメント文字列)
    comments_before_elem: list[tuple[ET.Element, str]] = []
    # 削除された要素の記録: (挿入基準となるafter子要素またはNone, コメント文字列)
    deletion_comments: list[tuple[ET.Element | None, str]] = []

    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue

        elif tag == "replace":
            b_slice = b_children[i1:i2]
            a_slice = a_children[j1:j2]
            pair_count = min(len(b_slice), len(a_slice))

            for k in range(pair_count):
                b_child = b_slice[k]
                a_child = a_slice[k]
                if b_child.tag == a_child.tag and not is_atomic_element(a_child):
                    # 同じコンテナタグ同士ならさらに深く比較
                    compare_and_mark_elements(
                        b_child, a_child, author, timestamp, changes_log
                    )
                else:
                    old_txt = truncate_text(normalize_text(b_child))
                    new_txt = truncate_text(normalize_text(a_child))
                    a_child.set("status", "changed")
                    a_child.set("rev", rev_value)
                    summary = f"[{a_child.tag}] 「{old_txt}」 → 「{new_txt}」"
                    changes_log.append(summary)
                    comments_before_elem.append(
                        (
                            a_child,
                            f" [変更履歴] {timestamp} | 変更者: {author} | {summary} ",
                        )
                    )

            # 置換ブロック内で余剰となった追加分
            for a_child in a_slice[pair_count:]:
                new_txt = truncate_text(normalize_text(a_child))
                a_child.set("status", "new")
                a_child.set("rev", rev_value)
                summary = f"[{a_child.tag}] 追加: 「{new_txt}」"
                changes_log.append(summary)
                comments_before_elem.append(
                    (
                        a_child,
                        f" [変更履歴] {timestamp} | 変更者: {author} | {summary} ",
                    )
                )

            # 置換ブロック内で余剰となった削除分
            anchor = a_children[j2] if j2 < len(a_children) else None
            for b_child in b_slice[pair_count:]:
                old_txt = truncate_text(normalize_text(b_child))
                summary = f"[{b_child.tag}] 削除: 「{old_txt}」"
                changes_log.append(summary)
                deletion_comments.append(
                    (
                        anchor,
                        f" [変更履歴] {timestamp} | 変更者: {author} | {summary} ",
                    )
                )

        elif tag == "insert":
            for a_child in a_children[j1:j2]:
                new_txt = truncate_text(normalize_text(a_child))
                a_child.set("status", "new")
                a_child.set("rev", rev_value)
                summary = f"[{a_child.tag}] 追加: 「{new_txt}」"
                changes_log.append(summary)
                comments_before_elem.append(
                    (
                        a_child,
                        f" [変更履歴] {timestamp} | 変更者: {author} | {summary} ",
                    )
                )

        elif tag == "delete":
            anchor = a_children[j1] if j1 < len(a_children) else None
            for b_child in b_children[i1:i2]:
                old_txt = truncate_text(normalize_text(b_child))
                summary = f"[{b_child.tag}] 削除: 「{old_txt}」"
                changes_log.append(summary)
                deletion_comments.append(
                    (
                        anchor,
                        f" [変更履歴] {timestamp} | 変更者: {author} | {summary} ",
                    )
                )

    # 親要素へのコメント挿入（後ろから挿入してインデックスずれを防ぐ）
    for target_elem, comment_text in reversed(comments_before_elem):
        children_now = list(after_elem)
        if target_elem in children_now:
            idx = children_now.index(target_elem)
            comment_node = ET.Comment(comment_text)
            comment_node.tail = "\n  "
            after_elem.insert(idx, comment_node)

    for anchor_elem, comment_text in reversed(deletion_comments):
        comment_node = ET.Comment(comment_text)
        comment_node.tail = "\n  "
        children_now = list(after_elem)
        if anchor_elem is not None and anchor_elem in children_now:
            idx = children_now.index(anchor_elem)
            after_elem.insert(idx, comment_node)
        else:
            after_elem.append(comment_node)


def ensure_prolog(root: ET.Element) -> ET.Element:
    """ルート要素内の適切な位置に <prolog> を取得または新規挿入する"""
    prolog = root.find("prolog")
    if prolog is not None:
        return prolog

    prolog = ET.Element("prolog")
    children = list(root)
    insert_idx = len(children)
    for i, child in enumerate(children):
        if isinstance(child.tag, str) and child.tag in BODY_AND_AFTER_TAGS:
            insert_idx = i
            break
    root.insert(insert_idx, prolog)
    return prolog


def append_prolog_history(
    root: ET.Element,
    author: str,
    timestamp: str,
    changes_log: list[str],
    note: str,
    mode: str,
) -> None:
    """<prolog> 内に変更履歴メタデータを記録する"""
    prolog = ensure_prolog(root)
    date_only = timestamp.split(" ")[0].split("T")[0]
    summary_text = "; ".join(changes_log)
    if note:
        summary_text = f"【備考: {note}】 {summary_text}"

    if mode == "dita13":
        # DITA 1.3 標準の <change-historylist> 形式
        history_list = prolog.find("change-historylist")
        if history_list is None:
            history_list = ET.SubElement(prolog, "change-historylist")

        item = ET.SubElement(history_list, "change-item")
        person = ET.SubElement(item, "change-person")
        person.text = author
        completed = ET.SubElement(item, "change-completed")
        completed.text = timestamp
        summary = ET.SubElement(item, "change-summary")
        summary.text = summary_text
        ET.indent(history_list, space="  ", level=2)
    else:
        # DITA 1.2 / 1.3 汎用互換形式（<critdates><revised> + <metadata><data>）
        critdates = prolog.find("critdates")
        if critdates is None:
            critdates = ET.Element("critdates")
            prolog.insert(0, critdates)

        revised = ET.SubElement(critdates, "revised")
        revised.set("modified", date_only)
        revised.set("golive", timestamp)
        revised.set("expiry", author)
        ET.indent(critdates, space="  ", level=2)

        metadata = prolog.find("metadata")
        if metadata is None:
            metadata = ET.SubElement(prolog, "metadata")

        data_elem = ET.SubElement(metadata, "data")
        data_elem.set("name", "change-history")
        data_elem.set("value", f"[{timestamp}] {author}: {summary_text}")
        ET.indent(metadata, space="  ", level=2)

    prolog.tail = "\n  "


def process_dita_folders(
    before_dir: Path,
    after_dir: Path,
    output_dir: Path,
    author: str,
    timestamp: str,
    note: str,
    mode: str,
    log_callback,
) -> tuple[int, int, int]:
    """フォルダ内の全DITAファイルを比較・処理する"""
    modified_count = 0
    new_count = 0
    unchanged_count = 0

    target_exts = {".dita", ".xml"}
    after_files = [
        p for p in after_dir.rglob("*") if p.is_file() and p.suffix.lower() in target_exts
    ]

    if not after_files:
        log_callback("警告: 変更後フォルダ内に .dita / .xml ファイルが見つかりませんでした。\n")
        return 0, 0, 0

    for after_path in sorted(after_files):
        rel_path = after_path.relative_to(after_dir)
        before_path = before_dir / rel_path
        out_path = output_dir / rel_path
        out_path.parent.mkdir(parents=True, exist_ok=True)

        after_raw = after_path.read_text(encoding="utf-8")
        header = extract_xml_header(after_raw)

        try:
            after_root = ET.fromstring(after_raw)
        except ET.ParseError as e:
            log_callback(f"[スキップ: XML解析エラー] {rel_path} ({e})\n")
            shutil.copy2(after_path, out_path)
            continue

        changes_log: list[str] = []

        # ケース1: 変更前フォルダに存在しない（新規追加ファイル）
        if not before_path.exists():
            after_root.set("status", "new")
            after_root.set("rev", f"{timestamp} ({author})")
            changes_log.append("新規ファイル作成")
            append_prolog_history(
                after_root, author, timestamp, changes_log, note, mode
            )
            xml_body = ET.tostring(after_root, encoding="unicode")
            out_path.write_text(header + xml_body + "\n", encoding="utf-8")
            new_count += 1
            log_callback(f"[新規追加] {rel_path}\n")
            continue

        # ケース2: 変更前ファイルが存在する（差分比較）
        before_raw = before_path.read_text(encoding="utf-8")
        try:
            before_root = ET.fromstring(before_raw)
        except ET.ParseError as e:
            log_callback(f"[スキップ: 変更前XML解析エラー] {rel_path} ({e})\n")
            shutil.copy2(after_path, out_path)
            continue

        compare_and_mark_elements(
            before_root, after_root, author, timestamp, changes_log
        )

        if changes_log:
            append_prolog_history(
                after_root, author, timestamp, changes_log, note, mode
            )
            xml_body = ET.tostring(after_root, encoding="unicode")
            out_path.write_text(header + xml_body + "\n", encoding="utf-8")
            modified_count += 1
            log_callback(f"[変更あり: {len(changes_log)}箇所] {rel_path}\n")
            for item in changes_log:
                log_callback(f"    ・{item}\n")
        else:
            # 変更がないファイルは元のままコピー
            shutil.copy2(after_path, out_path)
            unchanged_count += 1
            log_callback(f"[変更なし] {rel_path}\n")

    return modified_count, new_count, unchanged_count


class DitaDiffHistoryApp:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.root.title("DITA 差分比較・変更履歴自動付与ツール")
        self.root.geometry("760x620")
        self.root.minsize(680, 540)

        self.before_var = tk.StringVar()
        self.after_var = tk.StringVar()
        self.output_var = tk.StringVar()
        self.author_var = tk.StringVar(value=os.environ.get("USERNAME", ""))
        self.timestamp_var = tk.StringVar()
        self.note_var = tk.StringVar()
        self.mode_var = tk.StringVar(value="compat")

        self._build_ui()

    def _build_ui(self) -> None:
        pad = {"padx": 10, "pady": 5}
        main_frame = ttk.Frame(self.root, padding=12)
        main_frame.pack(fill=tk.BOTH, expand=True)

        # --- 1. フォルダ設定 ---
        folder_frame = ttk.LabelFrame(main_frame, text="1. 対象フォルダ設定", padding=10)
        folder_frame.pack(fill=tk.X, **pad)
        folder_frame.columnconfigure(1, weight=1)

        ttk.Label(folder_frame, text="変更前フォルダ:").grid(row=0, column=0, sticky=tk.W, pady=3)
        ttk.Entry(folder_frame, textvariable=self.before_var).grid(
            row=0, column=1, sticky=tk.EW, padx=6
        )
        ttk.Button(
            folder_frame, text="参照...", command=lambda: self._select_dir(self.before_var)
        ).grid(row=0, column=2)

        ttk.Label(folder_frame, text="変更後フォルダ:").grid(row=1, column=0, sticky=tk.W, pady=3)
        ttk.Entry(folder_frame, textvariable=self.after_var).grid(
            row=1, column=1, sticky=tk.EW, padx=6
        )
        ttk.Button(
            folder_frame, text="参照...", command=self._select_after_dir
        ).grid(row=1, column=2)

        ttk.Label(folder_frame, text="出力先フォルダ:").grid(row=2, column=0, sticky=tk.W, pady=3)
        ttk.Entry(folder_frame, textvariable=self.output_var).grid(
            row=2, column=1, sticky=tk.EW, padx=6
        )
        ttk.Button(
            folder_frame, text="参照...", command=lambda: self._select_dir(self.output_var)
        ).grid(row=2, column=2)

        # --- 2. 変更履歴メタデータ設定 ---
        meta_frame = ttk.LabelFrame(main_frame, text="2. 変更履歴メタデータ", padding=10)
        meta_frame.pack(fill=tk.X, **pad)
        meta_frame.columnconfigure(1, weight=1)

        ttk.Label(meta_frame, text="変更者（必須）:").grid(row=0, column=0, sticky=tk.W, pady=3)
        ttk.Entry(meta_frame, textvariable=self.author_var).grid(
            row=0, column=1, sticky=tk.EW, padx=6
        )

        ttk.Label(meta_frame, text="タイムスタンプ:").grid(row=1, column=0, sticky=tk.W, pady=3)
        ts_box = ttk.Frame(meta_frame)
        ts_box.grid(row=1, column=1, sticky=tk.EW, padx=6)
        ts_box.columnconfigure(0, weight=1)
        ttk.Entry(ts_box, textvariable=self.timestamp_var).grid(
            row=0, column=0, sticky=tk.EW
        )
        ttk.Label(
            ts_box,
            text="※未指定時は実行時の現在時刻を自動使用",
            foreground="#555555",
        ).grid(row=0, column=1, padx=(8, 0))

        ttk.Label(meta_frame, text="変更備考（任意）:").grid(row=2, column=0, sticky=tk.W, pady=3)
        ttk.Entry(meta_frame, textvariable=self.note_var).grid(
            row=2, column=1, sticky=tk.EW, padx=6
        )

        ttk.Label(meta_frame, text="履歴出力形式:").grid(row=3, column=0, sticky=tk.W, pady=3)
        mode_box = ttk.Frame(meta_frame)
        mode_box.grid(row=3, column=1, sticky=tk.W, padx=6)
        ttk.Radiobutton(
            mode_box,
            text="標準互換（rev/status属性 + critdates/data + 差分コメント）",
            variable=self.mode_var,
            value="compat",
        ).pack(anchor=tk.W)
        ttk.Radiobutton(
            mode_box,
            text="DITA 1.3形式（rev/status属性 + change-historylist + 差分コメント）",
            variable=self.mode_var,
            value="dita13",
        ).pack(anchor=tk.W)

        # --- 3. 実行ボタン ---
        btn_frame = ttk.Frame(main_frame)
        btn_frame.pack(fill=tk.X, padx=10, pady=8)
        run_btn = ttk.Button(
            btn_frame,
            text="差分を比較して変更履歴を付与する",
            command=self._run,
        )
        run_btn.pack(side=tk.RIGHT, ipadx=12, ipady=4)

        # --- 4. 実行ログ ---
        log_frame = ttk.LabelFrame(main_frame, text="実行ログ", padding=8)
        log_frame.pack(fill=tk.BOTH, expand=True, **pad)
        self.log_area = scrolledtext.ScrolledText(
            log_frame, height=12, font=("Consolas", 9), state=tk.DISABLED
        )
        self.log_area.pack(fill=tk.BOTH, expand=True)

    def _select_dir(self, target_var: tk.StringVar) -> None:
        selected = filedialog.askdirectory()
        if selected:
            target_var.set(selected)

    def _select_after_dir(self) -> None:
        selected = filedialog.askdirectory()
        if selected:
            self.after_var.set(selected)
            if not self.output_var.get().strip():
                self.output_var.set(f"{selected}_with_history")

    def _append_log(self, text: str) -> None:
        self.log_area.configure(state=tk.NORMAL)
        self.log_area.insert(tk.END, text)
        self.log_area.see(tk.END)
        self.log_area.configure(state=tk.DISABLED)
        self.root.update_idletasks()

    def _run(self) -> None:
        before_str = self.before_var.get().strip()
        after_str = self.after_var.get().strip()
        output_str = self.output_var.get().strip()
        author = self.author_var.get().strip()
        timestamp = self.timestamp_var.get().strip()
        note = self.note_var.get().strip()
        mode = self.mode_var.get()

        if not before_str or not after_str or not output_str:
            messagebox.showwarning("入力エラー", "変更前・変更後・出力先の全フォルダを指定してください。")
            return

        before_dir = Path(before_str)
        after_dir = Path(after_str)
        output_dir = Path(output_str)

        if not before_dir.is_dir() or not after_dir.is_dir():
            messagebox.showerror("パスエラー", "変更前または変更後フォルダが存在しません。")
            return

        if before_dir.resolve() == after_dir.resolve():
            messagebox.showerror("パスエラー", "変更前と変更後に同じフォルダは指定できません。")
            return

        if not author:
            messagebox.showwarning("入力エラー", "「変更者」を入力してください。")
            return

        # タイムスタンプ未指定時は現在時刻を使用
        if not timestamp:
            timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

        self.log_area.configure(state=tk.NORMAL)
        self.log_area.delete("1.0", tk.END)
        self.log_area.configure(state=tk.DISABLED)

        self._append_log("=== 処理開始 ===\n")
        self._append_log(f"変更者: {author}\n")
        self._append_log(f"タイムスタンプ: {timestamp}\n")
        self._append_log(f"出力先: {output_dir}\n\n")

        mod_cnt, new_cnt, unch_cnt = process_dita_folders(
            before_dir=before_dir,
            after_dir=after_dir,
            output_dir=output_dir,
            author=author,
            timestamp=timestamp,
            note=note,
            mode=mode,
            log_callback=self._append_log,
        )

        summary = (
            f"\n=== 処理完了 ===\n"
            f"変更あり: {mod_cnt} 件 / 新規追加: {new_cnt} 件 / 変更なし: {unch_cnt} 件"
        )
        self._append_log(summary + "\n")
        messagebox.showinfo("完了", f"変更履歴の付与が完了しました。\n\n{summary}")


if __name__ == "__main__":
    root = tk.Tk()
    app = DitaDiffHistoryApp(root)
    root.mainloop()
