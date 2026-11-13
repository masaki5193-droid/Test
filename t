import pandas as pd
import json
import os
import re
import tkinter as tk
from tkinter import filedialog, messagebox
import math

def clean_val(val):
    if pd.isna(val): return ""
    val_str = str(val).replace('?', '').strip()
    if val_str.lower() == "nan": return ""
    return val_str

def get_col_val(row, col_names, df_columns):
    for name in col_names:
        if name in df_columns: return clean_val(row[name])
    return ""

def format_date_iso(date_str):
    """「YYYY年MM月DD日 8:00」を「YYYY-MM-DD」に整形（JSでの日付処理用）"""
    if not date_str or str(date_str) == "N/A": return ""
    s = str(date_str).split(' ')[0]
    s = s.replace('年', '-').replace('月', '-').replace('日', '')
    try:
        # yyyy-mm-dd形式に統一
        parts = s.split('-')
        if len(parts) == 3:
            return f"{parts[0]:04s}-{int(parts[1]):02d}-{int(parts[2]):02d}"
    except:
        pass
    return s

def main():
    root = tk.Tk()
    root.withdraw()
    file_path = filedialog.askopenfilename(
        title="WBSのExcelまたはCSVファイルを選択してください",
        filetypes=[("Excel files", "*.xlsx *.xls"), ("CSV files", "*.csv")]
    )
    
    if not file_path:
        print("キャンセルされました。")
        return

    try:
        if file_path.endswith('.csv'):
            try:
                df = pd.read_csv(file_path, encoding='utf-8-sig')
            except:
                df = pd.read_csv(file_path, encoding='cp932')
        else:
            df = pd.read_excel(file_path)
            
        tasks = []
        last_at_level = {}
        top_level_id = None
        
        for _, row in df.iterrows():
            raw_prog = get_col_val(row, ["達成率", "進捗率"], df.columns)
            try: progress = float(raw_prog)
            except: progress = 0.0

            lvl_str = get_col_val(row, ["アウトライン_レベル", "アウトライン"], df.columns)
            try: lvl = int(lvl_str)
            except: lvl = 1

            task_id = get_col_val(row, ["ID", "ＩＤ"], df.columns)
            
            # 親子関係の特定
            parent_id = None
            if lvl == 1:
                top_level_id = task_id
            elif lvl > 1:
                parent_id = last_at_level.get(lvl - 1)
                
            last_at_level[lvl] = task_id

            task = {
                'id': task_id,
                'level': lvl,
                'parent_id': parent_id,
                'top_parent_id': top_level_id if lvl > 1 else task_id,
                'name': get_col_val(row, ["タスク名"], df.columns),
                'work_hours': get_col_val(row, ["作業時間"], df.columns),
                'duration': get_col_val(row, ["期間"], df.columns),
                'start': format_date_iso(get_col_val(row, ["開始日"], df.columns)),
                'end': format_date_iso(get_col_val(row, ["終了日"], df.columns)),
                'resource': get_col_val(row, ["リソース名", "リソース"], df.columns),
                'progress': progress,
                'has_children': False # 後でJS側またはここで計算
            }
            tasks.append(task)

        # 子供を持つ親タスクのフラグ立て
        parent_ids = {t['parent_id'] for t in tasks if t['parent_id']}
        for t in tasks:
            if t['id'] in parent_ids:
                t['has_children'] = True

        json_data = json.dumps(tasks, ensure_ascii=False)

        html_content = f"""<!DOCTYPE html>
<html lang="ja">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>CYBER-WBS DASHBOARD</title>
    <style>
        :root {{
            --bg-color: #030712;
            --panel-bg: rgba(13, 22, 46, 0.7);
            --neon-blue: #00f3ff;
            --neon-purple: #bc13fe;
            --neon-green: #00ff66;
            --text-main: #e2e8f0;
            --text-muted: #64748b;
            --border-glow: rgba(0, 243, 255, 0.2);
        }}
        * {{ box-sizing: border-box; margin: 0; padding: 0; font-family: 'Segoe UI', system-ui, sans-serif; }}
        body {{ background: radial-gradient(circle at top, #0a1128 0%, var(--bg-color) 100%); color: var(--text-main); height: 100vh; display: flex; flex-direction: column; overflow: hidden; }}
        
        .header {{ padding: 15px 30px; display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid var(--border-glow); background: rgba(3, 7, 18, 0.8); backdrop-filter: blur(10px); z-index: 100; }}
        .header h1 {{ font-size: 1.5rem; letter-spacing: 3px; color: var(--neon-blue); text-shadow: 0 0 10px var(--neon-blue); }}
        
        .tabs {{ display: flex; gap: 15px; }}
        .tab-btn {{ background: transparent; border: 1px solid var(--text-muted); color: var(--text-muted); padding: 8px 20px; border-radius: 4px; cursor: pointer; font-weight: bold; letter-spacing: 1px; transition: 0.3s; }}
        .tab-btn:hover {{ border-color: var(--neon-blue); color: var(--neon-blue); box-shadow: 0 0 8px rgba(0,243,255,0.3) inset; }}
        .tab-btn.active {{ border-color: var(--neon-blue); color: var(--bg-color); background: var(--neon-blue); box-shadow: 0 0 10px var(--neon-blue); text-shadow: none; }}

        .view-container {{ flex: 1; overflow-y: auto; padding: 20px; position: relative; }}
        .view {{ display: none; height: 100%; }}
        .view.active {{ display: block; }}

        /* Dashboard Grid */
        .dashboard-grid {{ display: grid; grid-template-columns: 250px 1fr; gap: 20px; margin-bottom: 20px; }}
        
        .panel {{ background: var(--panel-bg); backdrop-filter: blur(8px); border: 1px solid var(--border-glow); border-radius: 8px; padding: 15px; box-shadow: 0 4px 20px rgba(0,0,0,0.5); display: flex; flex-direction: column; }}
        .panel-header {{ font-size: 1rem; color: var(--neon-purple); border-bottom: 1px solid rgba(188, 19, 254, 0.3); padding-bottom: 8px; margin-bottom: 15px; letter-spacing: 1px; }}
        
        /* Charts */
        .pie-container {{ display: flex; flex-direction: column; align-items: center; justify-content: center; flex: 1; }}
        .bar-chart {{ display: flex; flex-direction: column; gap: 12px; overflow-y: auto; max-height: 200px; padding-right: 5px; }}
        .bar-item {{ display: flex; align-items: center; gap: 10px; font-size: 0.85rem; }}
        .bar-label {{ width: 150px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }}
        .bar-track {{ flex: 1; background: rgba(255, 255, 255, 0.05); height: 6px; border-radius: 3px; position: relative; }}
        .bar-fill {{ height: 100%; background: linear-gradient(90deg, var(--neon-purple), var(--neon-blue)); box-shadow: 0 0 8px var(--neon-blue); border-radius: 3px; transition: 1s; }}
        .bar-percent {{ width: 40px; text-align: right; color: var(--neon-blue); font-family: monospace; }}

        /* Filters */
        .filter-bar {{ display: flex; gap: 15px; margin-bottom: 15px; align-items: center; }}
        .input-glow {{ background: rgba(0,0,0,0.5); border: 1px solid var(--text-muted); color: var(--text-main); padding: 8px 12px; border-radius: 4px; outline: none; transition: 0.3s; min-width: 200px; }}
        .input-glow:focus {{ border-color: var(--neon-blue); box-shadow: 0 0 10px rgba(0,243,255,0.2); }}
        
        /* Table */
        .table-container {{ overflow-x: auto; flex: 1; }}
        table {{ width: 100%; border-collapse: collapse; }}
        th, td {{ padding: 10px; text-align: left; border-bottom: 1px solid rgba(255, 255, 255, 0.05); font-size: 0.85rem; }}
        th {{ color: var(--neon-blue); position: sticky; top: 0; background: rgba(13, 22, 46, 0.95); z-index: 10; font-weight: 500; white-space: nowrap; }}
        tr:hover {{ background: rgba(0, 243, 255, 0.05); }}
        .lvl-1 {{ font-weight: bold; background: rgba(0, 243, 255, 0.03); border-left: 2px solid var(--neon-blue); }}
        
        .toggle-btn {{ cursor: pointer; color: var(--neon-purple); font-family: monospace; font-size: 1.1rem; font-weight: bold; margin-right: 8px; user-select: none; display: inline-block; width: 16px; text-align: center; }}
        .toggle-btn:hover {{ color: var(--neon-blue); text-shadow: 0 0 5px var(--neon-blue); }}
        
        /* Gantt Chart */
        .gantt-wrapper {{ display: flex; height: 100%; background: var(--panel-bg); border: 1px solid var(--border-glow); border-radius: 8px; overflow: hidden; }}
        .gantt-labels {{ width: 300px; border-right: 1px solid rgba(0,243,255,0.2); overflow-y: hidden; background: rgba(0,0,0,0.3); }}
        .gantt-timeline-container {{ flex: 1; overflow: auto; position: relative; }}
        .gantt-timeline {{ position: relative; min-height: 100%; }}
        
        .g-header {{ display: flex; background: rgba(13, 22, 46, 0.95); position: sticky; top: 0; z-index: 20; border-bottom: 1px solid rgba(0,243,255,0.2); }}
        .g-month {{ color: var(--text-muted); font-size: 0.75rem; text-align: center; border-right: 1px solid rgba(255,255,255,0.05); padding: 5px 0; }}
        
        .g-row-label {{ padding: 0 15px; font-size: 0.85rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; display: flex; align-items: center; border-bottom: 1px solid rgba(255,255,255,0.05); }}
        .g-row-bg {{ border-bottom: 1px solid rgba(255,255,255,0.02); position: absolute; width: 100%; }}
        .g-bar {{ position: absolute; height: 16px; border-radius: 3px; font-size: 0.7rem; color: #000; font-weight: bold; display: flex; align-items: center; padding: 0 5px; overflow: hidden; white-space: nowrap; cursor: pointer; transition: 0.2s; box-shadow: 0 0 8px currentColor; }}
        .g-bar:hover {{ filter: brightness(1.2); z-index: 10; }}
        
        /* Scrollbar */
        ::-webkit-scrollbar {{ width: 8px; height: 8px; }}
        ::-webkit-scrollbar-track {{ background: rgba(0,0,0,0.2); }}
        ::-webkit-scrollbar-thumb {{ background: rgba(0,243,255,0.3); border-radius: 4px; }}
        ::-webkit-scrollbar-thumb:hover {{ background: var(--neon-blue); }}
    </style>
</head>
<body>

    <div class="header">
        <h1>SYS-WBS DASHBOARD</h1>
        <div class="tabs">
            <button class="tab-btn active" onclick="switchTab('dashboard')">DETAILS & CHARTS</button>
            <button class="tab-btn" onclick="switchTab('calendar')">GANTT CALENDAR</button>
        </div>
    </div>

    <!-- DASHBOARD VIEW -->
    <div id="view-dashboard" class="view-container view active">
        <div class="dashboard-grid">
            <div class="panel">
                <div class="panel-header">TOTAL PROGRESS</div>
                <div class="pie-container" id="pie-chart-container"></div>
            </div>
            <div class="panel">
                <div class="panel-header">PHASE PROGRESS (Level 1 Auto-Calculated)</div>
                <div class="bar-chart" id="bar-chart-container"></div>
            </div>
        </div>

        <div class="panel" style="flex:1;">
            <div class="panel-header" style="display:flex; justify-content:space-between; align-items:center;">
                <span>TASK DETAILS</span>
                <div class="filter-bar">
                    <input type="text" id="searchInput" class="input-glow" placeholder="Search Task Name / ID..." onkeyup="applyFilter()">
                    <select id="resourceFilter" class="input-glow" onchange="applyFilter()">
                        <option value="">All Resources</option>
                    </select>
                </div>
            </div>
            <div class="table-container">
                <table id="wbs-table">
                    <thead>
                        <tr>
                            <th style="width: 80px;">ID</th>
                            <th>Task Name</th>
                            <th style="width: 150px;">Progress</th>
                            <th style="width: 120px;">Duration / Hrs</th>
                            <th style="width: 100px;">Start Date</th>
                            <th style="width: 100px;">End Date</th>
                            <th style="width: 150px;">Resource</th>
                        </tr>
                    </thead>
                    <tbody></tbody>
                </table>
            </div>
        </div>
    </div>

    <!-- CALENDAR (GANTT) VIEW -->
    <div id="view-calendar" class="view-container view">
        <div class="gantt-wrapper">
            <div class="gantt-labels" id="gantt-labels"></div>
            <div class="gantt-timeline-container" id="gantt-scroll" onscroll="syncScroll()">
                <div class="gantt-timeline" id="gantt-timeline"></div>
            </div>
        </div>
    </div>

    <script>
        let tasks = {json_data};
        let collapsedNodes = new Set();
        let isFiltering = false;

        function initData() {{
            // PHASE PROGRESS: Level 1タスクの進捗を子タスクの平均から自動計算
            const topLvlStats = {{}};
            tasks.forEach(t => {{
                if (t.level === 1) topLvlStats[t.id] = {{ sum: 0, count: 0 }};
            }});

            tasks.forEach(t => {{
                if (t.level > 1 && t.top_parent_id && topLvlStats[t.top_parent_id]) {{
                    topLvlStats[t.top_parent_id].sum += parseFloat(t.progress || 0);
                    topLvlStats[t.top_parent_id].count++;
                }}
            }});

            tasks.forEach(t => {{
                if (t.level === 1 && topLvlStats[t.id].count > 0) {{
                    t.progress = topLvlStats[t.id].sum / topLvlStats[t.id].count;
                }}
            }});

            // リソースフィルターの選択肢生成
            const resources = [...new Set(tasks.map(t => t.resource).filter(r => r))];
            const resSelect = document.getElementById('resourceFilter');
            resources.forEach(r => {{
                let opt = document.createElement('option');
                opt.value = r; opt.textContent = r;
                resSelect.appendChild(opt);
            }});
        }}

        function switchTab(viewId) {{
            document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
            document.querySelectorAll('.view').forEach(v => v.classList.remove('active'));
            
            event.target.classList.add('active');
            document.getElementById('view-' + viewId).classList.add('active');
            
            if(viewId === 'calendar' && !document.getElementById('gantt-timeline').innerHTML) {{
                renderGantt();
            }}
        }}

        function toggleCollapse(id) {{
            if(isFiltering) return; // フィルタリング中は折りたたみ無効
            if (collapsedNodes.has(id)) collapsedNodes.delete(id);
            else collapsedNodes.add(id);
            renderTable();
        }}

        function applyFilter() {{
            const txt = document.getElementById('searchInput').value.toLowerCase();
            const res = document.getElementById('resourceFilter').value;
            isFiltering = (txt !== '' || res !== '');
            renderTable();
        }}

        function renderDashboard() {{
            // 全体進捗 (Level 1タスクの平均)
            const lvl1Tasks = tasks.filter(t => t.level === 1);
            let avgProgress = lvl1Tasks.length ? (lvl1Tasks.reduce((s, t) => s + parseFloat(t.progress), 0) / lvl1Tasks.length) * 100 : 0;

            const radius = 60, circumference = 2 * Math.PI * radius;
            const offset = circumference - (avgProgress / 100) * circumference;

            document.getElementById('pie-chart-container').innerHTML = `
                <svg width="160" height="160" viewBox="0 0 140 140">
                    <circle cx="70" cy="70" r="${{radius}}" fill="none" stroke="rgba(255,255,255,0.05)" stroke-width="12" />
                    <circle cx="70" cy="70" r="${{radius}}" fill="none" stroke="#00f3ff" stroke-width="12"
                            stroke-dasharray="${{circumference}}" stroke-dashoffset="${{offset}}"
                            stroke-linecap="round" transform="rotate(-90 70 70)" style="filter: drop-shadow(0 0 8px #00f3ff);" />
                    <text x="70" y="78" text-anchor="middle" fill="#e2e8f0" font-size="24" font-family="monospace" font-weight="bold">${{avgProgress.toFixed(1)}}%</text>
                </svg>
            `;

            // PHASE PROGRESS
            let html = '';
            lvl1Tasks.forEach(t => {{
                const p = (parseFloat(t.progress) * 100).toFixed(0);
                html += `
                    <div class="bar-item">
                        <div class="bar-label" title="${{t.name}}">${{t.name}}</div>
                        <div class="bar-track">
                            <div class="bar-fill" style="width: ${{p}}%"></div>
                        </div>
                        <div class="bar-percent">${{p}}%</div>
                    </div>`;
            }});
            document.getElementById('bar-chart-container').innerHTML = html;
        }}

        function renderTable() {{
            const tbody = document.querySelector('#wbs-table tbody');
            const txt = document.getElementById('searchInput').value.toLowerCase();
            const res = document.getElementById('resourceFilter').value;

            // フィルター時の表示対象計算
            let visibleSet = new Set();
            if (isFiltering) {{
                tasks.forEach(t => {{
                    let match = true;
                    if(txt && !t.name.toLowerCase().includes(txt) && !String(t.id).includes(txt)) match = false;
                    if(res && t.resource !== res) match = false;
                    
                    if (match) {{
                        visibleSet.add(t.id);
                        // 親階層も表示リストに追加
                        let curr = tasks.find(x => x.id === t.parent_id);
                        while(curr) {{
                            visibleSet.add(curr.id);
                            curr = tasks.find(x => x.id === curr.parent_id);
                        }}
                    }}
                }});
            }}

            let html = '';
            tasks.forEach(t => {{
                // 表示判定
                if (isFiltering) {{
                    if (!visibleSet.has(t.id)) return;
                }} else {{
                    // 折りたたみ判定
                    let isHidden = false;
                    let curr = tasks.find(x => x.id === t.parent_id);
                    while(curr) {{
                        if(collapsedNodes.has(curr.id)) {{ isHidden = true; break; }}
                        curr = tasks.find(x => x.id === curr.parent_id);
                    }}
                    if (isHidden) return;
                }}

                const pad = (t.level - 1) * 20;
                const prog = (parseFloat(t.progress) * 100).toFixed(0);
                const isLvl1 = t.level === 1 ? 'lvl-1' : '';
                
                let toggleIcon = '<span style="display:inline-block; width:16px;"></span>';
                if (t.has_children) {{
                    const icon = collapsedNodes.has(t.id) ? '+' : '-';
                    toggleIcon = `<span class="toggle-btn" onclick="toggleCollapse('${{t.id}}')">[${{icon}}]</span>`;
                }}

                html += `
                    <tr class="${{isLvl1}}">
                        <td style="color: var(--text-muted)">${{t.id}}</td>
                        <td style="padding-left: ${{pad + 10}}px;">
                            ${{toggleIcon}}
                            ${{t.name}}
                        </td>
                        <td>
                            <div style="display:flex; align-items:center; gap:8px;">
                                <div style="width:60px; background:rgba(255,255,255,0.1); height:6px; border-radius:3px;">
                                    <div style="height:100%; width:${{prog}}%; background:var(--neon-green); box-shadow:0 0 5px var(--neon-green); border-radius:3px;"></div>
                                </div>
                                <span style="font-family:monospace; font-size:0.8rem;">${{prog}}%</span>
                            </div>
                        </td>
                        <td style="font-size:0.8rem; color:var(--text-muted);">${{t.duration||'-'}} / ${{t.work_hours||'-'}}</td>
                        <td style="font-family:monospace;">${{t.start}}</td>
                        <td style="font-family:monospace;">${{t.end}}</td>
                        <td>${{t.resource}}</td>
                    </tr>
                `;
            }});
            tbody.innerHTML = html;
        }}

        function renderGantt() {{
            const labelsContainer = document.getElementById('gantt-labels');
            const timelineContainer = document.getElementById('gantt-timeline');
            
            const validTasks = tasks.filter(t => t.start && t.end);
            if(validTasks.length === 0) {{ labelsContainer.innerHTML = '日付データがありません'; return; }}

            // 最小・最大のタイムスタンプ取得
            let minDate = Math.min(...validTasks.map(t => new Date(t.start).getTime()));
            let maxDate = Math.max(...validTasks.map(t => new Date(t.end).getTime()));
            
            const dayMs = 24 * 60 * 60 * 1000;
            minDate -= dayMs * 7; // 前後に7日の余白
            maxDate += dayMs * 14; 
            
            const totalDays = Math.ceil((maxDate - minDate) / dayMs);
            const dayWidth = 4; // 1日あたりのピクセル数
            const rowHeight = 35;

            // ヘッダー作成 (年月)
            let headerHtml = `<div class="g-header" style="width:${{totalDays * dayWidth}}px; height: 35px;">`;
            let currentMonth = '';
            let monthDays = 0;
            
            for(let i=0; i<totalDays; i++) {{
                const d = new Date(minDate + i * dayMs);
                const m = d.getFullYear() + '-' + String(d.getMonth()+1).padStart(2,'0');
                if (m !== currentMonth) {{
                    if(currentMonth !== '') {{
                        headerHtml += `<div class="g-month" style="width:${{monthDays * dayWidth}}px">${{currentMonth}}</div>`;
                    }}
                    currentMonth = m;
                    monthDays = 1;
                }} else {{
                    monthDays++;
                }}
            }}
            headerHtml += `<div class="g-month" style="width:${{monthDays * dayWidth}}px">${{currentMonth}}</div></div>`;

            // ラベルとバーの描画
            let labelsHtml = `<div style="height:35px; border-bottom:1px solid rgba(0,243,255,0.2); background:rgba(13,22,46,0.95);"></div>`;
            let barsHtml = headerHtml;

            let yOffset = 35;
            tasks.forEach(t => {{
                // 左側のラベル
                const pad = (t.level - 1) * 15;
                const color = t.level === 1 ? 'var(--neon-blue)' : 'var(--text-main)';
                const fontWeight = t.level === 1 ? 'bold' : 'normal';
                
                labelsHtml += `<div class="g-row-label" style="height:${{rowHeight}}px; padding-left:${{pad + 10}}px; color:${{color}}; font-weight:${{fontWeight}};" title="${{t.name}}">${{t.name}}</div>`;
                
                // 右側の背景罫線
                barsHtml += `<div class="g-row-bg" style="top:${{yOffset}}px; height:${{rowHeight}}px;"></div>`;
                
                // バー描画
                if (t.start && t.end) {{
                    const sTime = new Date(t.start).getTime();
                    const eTime = new Date(t.end).getTime();
                    const startX = (sTime - minDate) / dayMs * dayWidth;
                    const w = Math.max((eTime - sTime) / dayMs * dayWidth, 4);
                    
                    const barColor = t.level === 1 ? 'var(--neon-purple)' : 'var(--neon-blue)';
                    const textColor = t.level === 1 ? '#fff' : '#000';
                    const prog = (parseFloat(t.progress) * 100).toFixed(0);
                    
                    barsHtml += `
                        <div class="g-bar" style="top:${{yOffset + 10}}px; left:${{startX}}px; width:${{w}}px; background:${{barColor}}; color:${{textColor}};" title="${{t.name}} (${{prog}}%)">
                            ${{prog}}%
                        </div>`;
                }}
                yOffset += rowHeight;
            }});

            labelsContainer.innerHTML = labelsHtml;
            timelineContainer.innerHTML = barsHtml;
            timelineContainer.style.width = (totalDays * dayWidth) + 'px';
            timelineContainer.style.height = yOffset + 'px';
        }}

        function syncScroll() {{
            const timeline = document.getElementById('gantt-scroll');
            const labels = document.getElementById('gantt-labels');
            labels.scrollTop = timeline.scrollTop;
        }}

        // Initialize
        document.addEventListener('DOMContentLoaded', () => {{
            initData();
            renderDashboard();
            renderTable();
        }});
    </script>
</body>
</html>"""

        output_dir = os.path.dirname(os.path.abspath(file_path))
        output_file = os.path.join(output_dir, 'cyber_wbs_dashboard.html')
        
        with open(output_file, 'w', encoding='utf-8') as f:
            f.write(html_content)
            
        print(f"✅ 作成完了: {output_file}")
        try:
            messagebox.showinfo("完了", f"ダッシュボードの作成が完了しました。\n\n保存先:\n{output_file}")
        except:
            pass

    except Exception as e:
        print(f"❌ エラーが発生しました: {e}")
        try:
            messagebox.showerror("エラー", f"処理中にエラーが発生しました:\n{e}")
        except:
            pass

if __name__ == "__main__":
    main()
