#!/usr/bin/env python3
"""Catch translations that drifted away from the English they came from.

The `en` VALUE is the baseline, never the catalog key: some keys are explicit
identifiers (`error.app.file_access_denied`) whose text lives only in the value,
so comparing a key's placeholders against a value's reports every one of them.

Three failures, in descending severity:

  1. the placeholder set differs from `en` — the wrong value gets substituted,
     or `String(format:)` reads past its arguments
  2. a language is absent while `en` is present — that language silently falls
     back to English
  3. a language is present but not marked translated — it is a placeholder
     someone still has to write

Then the copy rules, which keep one wording per language:

  4. TERM: a concept has one name per language (`TERMS`); allowed compounds
     are blanked out before the banned pattern is searched
  5. PUNCT: zh-Hans / zh-Hant punctuation, quotes and spacing (`PUNCT`), and
     UI paths in every translation written as one quoted `A › B` (`PATH_RULES`)
  6. ELLIPSIS: a translation ends with "…" exactly when its English does

Xcode omits the `en` entry entirely when the key *is* the English string; those
keys are checked against the key instead, which is the same text.

    python3 scripts/check_localization_drift.py [--self-test]
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / 'LiveWallpaper/Resources/Localizable.xcstrings'
REQUIRED = ('ja', 'zh-Hans', 'zh-Hant', 'es')

# %@  %1$@  %lld  %2$lld  %.2f  %03d
PLACEHOLDER = re.compile(r'%(?:\d+\$)?[-+ #0]*[\d.*]*(?:@|lld|ld|d|u|f|s)')

CJK = r'[\u3400-\u9fff\uf900-\ufaff]'

# (rule id, language, banned regex, allowed compounds blanked out first, use instead)
TERMS = [
    # display: the device is 显示器, classifier 台
    ('display', 'zh-Hans', r'屏幕|屏', r'锁屏|全屏|截屏|录屏|黑屏|超宽屏|屏幕保护程序|屏幕使用时间|(填满|填充|适合于?)屏幕|显示在屏幕上|屏幕上', '显示器'),
    ('display-cl', 'zh-Hans', r'(这|那|每|哪|一|第一|几|两|三|%lld|%\d\$lld|\d) ?块(?=显示器|屏幕|屏)', None, '台'),
    ('display', 'zh-Hant', r'螢幕', r'螢幕保護程式|全螢幕|鎖定螢幕|螢幕錄製|螢幕截圖|螢幕使用時間|超寬螢幕|(填滿|符合)螢幕|顯示在螢幕上|螢幕上', '顯示器'),
    ('display-cl', 'zh-Hant', r'(這|那|每|哪|一|第一|幾|兩|三|%lld|%\d\$lld|\d) ?[塊部個](?=顯示器|螢幕)', None, '台'),
    ('display', 'ja', r'画面', r'全画面|ロック画面|画面収録|画面共有|画面全体|画面いっぱい|画面上|画面に表示', 'ディスプレイ'),
    # playlist / schedule
    ('playlist', 'zh-Hans', r'队列', r'下载队列|命令队列', '播放列表（创意工坊粘贴面板的是"下载队列"）'),
    ('schedule', 'zh-Hans', r'日程|排程|时间表|(?<!锁)定时', None, '计划'),
    ('playlist', 'zh-Hant', r'佇列|播放清單', r'下載佇列|命令佇列', '播放列表（下載佇列除外）'),
    ('schedule', 'zh-Hant', r'時間表|日程|時程|(?<!鎖)定時', None, '排程'),
    ('playlist', 'ja', r'(?<![\u30a0-\u30ff])キュー', r'ダウンロードキュー|コマンドキュー', 'プレイリスト（ダウンロードキュー除外）'),
    ('playlist', 'es', r'(?i:\bcola\b|listas? de reproducción)', r'(?i:colas? de descargas?|cola de comandos)', 'playlist（cola de descargas 除外）'),
    ('schedule', 'es', r'\b[Hh]orario', None, 'programación'),
    # own library; other libraries keep their qualifier
    ('library', 'zh-Hans', r'资料库|图库|素材库|资源库|我库|我的库|你的库|完整库|已保存(?=移除|中|$)|(?<![壁纸航拍])库',
     r'壁纸库|Steam 库|航拍库|系统壁纸库|Wallpaper Engine 库|着色器库|仓库', '壁纸库；其他库带限定词'),
    # zh-Hant 儲存庫 = repository (the Git / GitHub zh-TW word), not a library
    ('library', 'zh-Hant', r'圖庫|素材庫|媒體庫|壁紙庫|我的庫|你的庫|資料庫|(?<![桌布資料藏拍照圖])庫',
     r'桌布庫|系統桌布庫|Steam 收藏庫|收藏庫|空照圖庫|空拍庫|Wallpaper Engine 庫|程式庫|倉庫|儲存庫', '桌布庫'),
    # wallpaper: the app's object vs. Apple's settings pane
    # "macOS 墙纸" names the macOS desktop picture itself (e.g. "设为 macOS 墙纸"); the settings path form is for navigation
    ('wallpaper', 'zh-Hans', r'墙纸', r'系统设置 › 墙纸|“墙纸”|动态墙纸|macOS 墙纸', '壁纸（引用 macOS 时写“系统设置 › 墙纸”或“macOS 墙纸”）'),
    # zh-Hant "macOS 背景圖片" names the macOS desktop picture itself (e.g. "設為 macOS 背景圖片"), like zh-Hans "macOS 墙纸"
    ('wallpaper', 'zh-Hant', r'壁紙|背景圖片', r'系統設定 › 背景圖片|「背景圖片」|動態背景圖片|macOS 背景圖片', '桌布（引用 macOS 時寫「系統設定 › 背景圖片」）'),
    # aerials
    ('aerial', 'zh-Hans', r'Aerials?', None, '航拍（Apple Aerials → Apple 航拍）'),
    ('aerial', 'zh-Hant', r'Aerials?|空拍|航拍', None, '空照圖'),
    ('aerial', 'ja', r'Aerials?', None, '空撮'),
    ('aerial', 'es', r'Aerials?', None, 'vistas aéreas'),
    # workshop / subscribe
    ('workshop', 'zh-Hans', r'Workshop', r'Workshop ID', '创意工坊'),
    ('workshop', 'zh-Hant', r'Workshop|創意工坊', r'Workshop ID', '工作坊'),
    ('workshop', 'ja', r'Workshop', r'Workshop ID', 'ワークショップ'),
    ('subscribe', 'ja', r'購読|登録', None, 'サブスクライブ'),
    # this Mac: each language follows its Apple menu item (关于本机 / 關於這台 Mac / このMacについて / Acerca de este Mac)
    ('this-mac', 'zh-Hans', r'这台 Mac|此 Mac', None, '本机'),
    ('this-mac', 'zh-Hant', r'此 Mac|本機(?!資料夾|檔案|磁碟|開發|位址|伺服器)', None, '這台 Mac'),
    ('this-mac', 'ja', r'このMac', None, 'この Mac'),
    # widget
    ('widget', 'zh-Hans', r'(?<!小)组件|仪表|监控壁纸|浮层|板已满', r'软件组件|其他组件', '小组件 / 图层'),
    ('widget', 'zh-Hant', r'元件|儀表|浮層', r'其他元件', '小工具'),  # 其他元件 = other software components ("沒有其他元件會讀取它們"), like zh-Hans 其他组件
    # macOS references: Apple's own names
    ('macos-ref', 'zh-Hans', r'桌面图片|系统设置[^。；，]{0,10}壁纸|壁纸设置(?=[”」]|$)', None, '墙纸（“系统设置 › 墙纸”）'),
    ('macos-ref', 'zh-Hant', r'桌面圖片|系統設定[^。；，]{0,10}桌布|桌布設定(?=[」]|$)', None, '背景圖片'),
    ('macos-ref', 'zh-Hans', r'屏保', None, '屏幕保护程序'),
    ('macos-ref', 'zh-Hans', r'通用 ?[→›>] ?登录项(?!与扩展)', None, '登录项与扩展'),
    # generic zh wording
    ('other', 'zh-Hans', r'其它', None, '其他'),
    ('you', 'zh-Hans', r'您', r'指定您希望搜索的项目文本字段：', '你'),  # Steam's own UI text, verbatim; WorkshopSortCopyTests.steamCopyIsVerbatim locks it
    ('you', 'zh-Hant', r'您', r'指定您想搜尋的項目文字欄位：', '你'),  # Steam's own zh-Hant UI text, verbatim (Workshop_SearchTarget_MenuTitle in steamcommunity's tchinese localization bundle)
    ('colloquial', 'zh-Hans', r'试试|放点东西|不用选|随时再换|收好|给[^。，]{1,8}一张|上次壁纸应用失败|上次 %@|明确的成人内容|现在单独登录', None, '书面语（不用口语）'),
    ('colloquial', 'zh-Hant', r'試試|放點東西|不用選|隨時再換|收好|給[^。，]{1,8}一張|上次 %@|明確的成人內容|現在會單獨登入', None, '書面語（不用口語）'),
    # undo / redo
    ('undo', 'zh-Hans', r'撤消|复原', None, '撤销 / 重做'),
    ('undo', 'zh-Hant', r'撤銷|撤消|復原', None, '還原 / 重做'),
    ('undo', 'ja', r'元に戻す|やり直し(?!す)', None, '取り消す / やり直す'),
]
# rules that only apply when the English names the concept
EN_SCOPE = {
    ('subscribe', 'ja'): r'subscri',
    ('schedule', 'es'): r'schedul',
    ('display', 'ja'): r'\bdisplays?\b',
    ('this-mac', 'zh-Hant'): r'this Mac',
    ('undo', 'zh-Hans'): r'\bundo\b|\bredo\b',
    ('undo', 'zh-Hant'): r'\bundo\b|\bredo\b',
    ('undo', 'ja'): r'\bundo\b|\bredo\b',
}
# (rule id, language, key) -> reason
EXEMPT = {
    ('display', 'zh-Hans', 'Screen frame'): 'HUD safe-area frame line: the picture border, not the device',
    ('display', 'zh-Hant', 'Screen frame'): 'same as above',
    ('library', 'zh-Hans', 'Saved'): 'legacy sidebar page name "已保存"; a page name follows the UI it is on',
    ('library', 'zh-Hant', 'Saved'): 'same as above',
}

# zh only
PUNCT = [
    ('halfwidth-punct', r'(?<=' + CJK + r')[,;!?]|[,;!?](?=' + CJK + r')', '，；！？'),
    ('halfwidth-colon', r'(?<=' + CJK + r'):|(?<![A-Za-z0-9/]):(?=' + CJK + r')', '：'),
    ('halfwidth-paren', r'(?<![A-Za-z0-9_\]])\((?![^()]*\)\s*[A-Za-z])|\)(?=' + CJK + r')|\([^()]*' + CJK + r'[^()]*\)', '（）'),
    ('quote-hans', r'[「」『』《》"]', '“”'),
    ('quote-hant', r'[“”《》"]', '「」'),
    ('ascii-ellipsis', r'\.\.\.', '…'),
    ('dash', r'(?<!—)—(?!—)| —|— ', '——（两字宽，前后不留空格）'),
    ('space-in-cjk', r'(?<=' + CJK + r') +(?=' + CJK + r')', '删除空格'),
    ('space-around-fullwidth', r' (?=[，。；：！？、）」”])|(?<=[，。；：！？、（「“]) ', '删除空格'),
    ('cjk-latin-nospace', r'(?<=' + CJK + r')[A-Za-z]|[A-Za-z](?=' + CJK + r')', '中文与英文之间加一个空格'),
]
PUNCT_LANGS = ('zh-Hans', 'zh-Hant')
# UI paths, all four languages: separator ' › ', the whole path inside one pair of quotes
PATH_RULES = [
    ('path-arrow', r'[^\s（(←]\s*→\s*[^\s)）]', '路径分隔符写 › （前后各一个空格）'),
    ('path-quote', r'[”」]\s*[›→]\s*[“「]', '整条路径只加一对引号'),
]
# (rule, language) turns a PUNCT rule off for a language; (rule, language, key) for one value
PUNCT_SKIP = {
    ('quote-hans', 'zh-Hant'),
    ('quote-hant', 'zh-Hans'),
    ('space-in-cjk', 'zh-Hans', 'System Normal'),  # capsule headline, design original
    ('space-in-cjk', 'zh-Hant', 'System Normal'),
    ('space-in-cjk', 'zh-Hans', 'ESC Close · ← → Adjacent wallpapers · Space Play/Pause'),  # key legend: the space separates the key name 空格 from its action, like "ESC 关闭"
    ('space-in-cjk', 'zh-Hans', 'ESC Close · ← → Adjacent wallpapers · Space Play/Pause on desktop'),  # same key legend
    ('space-in-cjk', 'zh-Hant', 'ESC Close · ← → Adjacent wallpapers · Space Play/Pause'),  # same key legend: the key name 空白鍵 and its action, like "ESC 關閉"
    ('space-in-cjk', 'zh-Hant', 'ESC Close · ← → Adjacent wallpapers · Space Play/Pause on desktop'),  # same key legend
}
# kept half-width: code spans, markdown link targets, format specifiers, URLs, shortcut glyph runs, digit ranges/times
CODE_SPAN = re.compile(r'`[^`]*`|\]\([^)]*\)|' + PLACEHOLDER.pattern + r'|https?://\S+|'
                       r'[⌘⌥⌃⇧][^ ]*|\d[:.–]\d')


def signature(text):
    """Conversion types only, sorted, so `%@ %@` and `%1$@ %2$@` compare equal.

    Position is deliberately discarded: a translation is expected to reorder
    its placeholders, and a reorder is correct as long as the same set of
    values is consumed.
    """
    kinds = []
    for match in PLACEHOLDER.finditer(text):
        raw = match.group(0).lstrip('%').split('$')[-1]
        kinds.append(raw.lstrip('-+ #0123456789.*'))
    return sorted(kinds)


def audit(catalog):
    mismatch, missing, untranslated = [], [], []
    for key, entry in catalog.get('strings', {}).items():
        localizations = entry.get('localizations') or {}
        if not localizations:
            continue
        english = localizations.get('en', {}).get('stringUnit', {}).get('value')
        base = signature(english if english is not None else key)

        for lang in REQUIRED:
            unit = localizations.get(lang, {}).get('stringUnit')
            if unit is None:
                missing.append((key, lang))
                continue
            if unit.get('state') != 'translated':
                untranslated.append((key, lang, unit.get('state')))
            found = signature(unit.get('value', ''))
            if found != base:
                mismatch.append((key, lang, base, found))
    return mismatch, missing, untranslated


def blank(text, pattern):
    """Overwrite each match with as many em spaces, so no rule can match inside it."""
    return re.sub(pattern, lambda m: '\u2003' * len(m.group(0)), text) if pattern else text


def copy_audit(catalog):
    terms, punct, ellipsis = [], [], []
    for key, entry in catalog.get('strings', {}).items():
        localizations = entry.get('localizations') or {}
        if not localizations:
            continue
        english = localizations.get('en', {}).get('stringUnit', {}).get('value')
        english = english if english is not None else key
        value = {lang: (localizations.get(lang, {}).get('stringUnit') or {}).get('value') or ''
                 for lang in REQUIRED}

        for rule, lang, bad, allow, use in TERMS:
            scope = EN_SCOPE.get((rule, lang))
            if not value[lang] or (rule, lang, key) in EXEMPT:
                continue
            if scope and not re.search(scope, english, re.I):
                continue
            found = re.search(bad, blank(value[lang], allow))
            if found:
                terms.append((key, lang, rule, found.group(0), use))

        for rule, pattern, use in PUNCT:
            for lang in PUNCT_LANGS:
                if not value[lang] or (rule, lang) in PUNCT_SKIP or (rule, lang, key) in PUNCT_SKIP:
                    continue
                found = re.search(pattern, blank(value[lang], CODE_SPAN))
                if found:
                    punct.append((key, lang, rule, found.group(0), use))
        for rule, pattern, use in PATH_RULES:
            for lang in REQUIRED:
                found = re.search(pattern, value[lang].replace('← →', ''))  # arrow-key legend, not a path
                if found:
                    punct.append((key, lang, rule, found.group(0), use))

        trails = english.rstrip().endswith(('…', '...'))
        for lang in REQUIRED:
            text = value[lang].rstrip()
            if text and text.endswith(('…', '...')) != trails:
                ellipsis.append((key, lang, trails))
    return terms, punct, ellipsis


def self_test():
    """The guard has to fail on a drifted catalog, or it guards nothing."""
    def unit(value, state='translated'):
        return {'stringUnit': {'state': state, 'value': value}}

    drifted = {'strings': {
        'Linked %lld of %lld': {'localizations': {
            'en': unit('Linked %lld of %lld'),
            'ja': unit('%lld 件をリンク'),          # one placeholder lost
            'zh-Hans': unit('已链接 %lld / %lld'),
            'zh-Hant': unit('已連結 %lld / %lld'),
            'es': unit('Vinculados %lld de %lld'),
        }},
        'Reordered %1$@ then %2$@': {'localizations': {
            'en': unit('Reordered %1$@ then %2$@'),
            'ja': unit('%2$@ のあとに %1$@'),        # reorder: legal
            'zh-Hans': unit('先 %2$@ 再 %1$@'),
            'zh-Hant': unit('先 %2$@ 再 %1$@'),
            'es': unit('%2$@ y luego %1$@'),
        }},
        'Absent language': {'localizations': {
            'en': unit('Absent language'),
            'ja': unit('言語なし'),
            'zh-Hans': unit('缺语言'),
            'es': unit('Idioma ausente'),
        }},
        'Still a stub': {'localizations': {
            'en': unit('Still a stub'),
            'ja': unit('', 'new'),
            'zh-Hans': unit('存根'),
            'zh-Hant': unit('存根'),
            'es': unit('Borrador'),
        }},
    }}
    mismatch, missing, untranslated = audit(drifted)
    assert [m[0] for m in mismatch] == ['Linked %lld of %lld'], mismatch
    assert missing == [('Absent language', 'zh-Hant')], missing
    assert [u[0] for u in untranslated] == ['Still a stub'], untranslated

    clean = {'strings': {'All good %@': {'localizations': {
        'en': unit('All good %@'), 'ja': unit('問題なし %@'),
        'zh-Hans': unit('没问题 %@'), 'zh-Hant': unit('沒問題 %@'),
        'es': unit('Todo bien %@'),
    }}}}
    assert audit(clean) == ([], [], []), audit(clean)
    assert copy_audit(clean) == ([], [], []), copy_audit(clean)

    copy = {'strings': {
        'Copy to Other Displays': {'localizations': {
            'zh-Hans': unit('复制到其他屏幕')}},
        'Capture while locked': {'localizations': {
            'zh-Hans': unit('锁屏时截取')}},           # allowed compound
        'Linked %lld, skipped %lld.': {'localizations': {
            'zh-Hans': unit('已链接 %lld 个,跳过 %lld 个。')}},
        'Version 0.7.1, updated at 12:00': {'localizations': {
            'zh-Hans': unit('版本 0.7.1，于 12:00 更新')}},  # half-width digits
        'Connecting…': {'localizations': {
            'zh-Hans': unit('正在连接'), 'ja': unit('接続中…')}},
        'Workshop': {'localizations': {'zh-Hant': unit('創意工坊')}},
        'Playlist': {'localizations': {
            'zh-Hant': unit('播放清單'), 'es': unit('Lista de reproducción')}},
        'MP4 / MOV files and playlists': {'localizations': {
            'es': unit('Archivos MP4 / MOV y listas de reproducción')}},
        'Download queue': {'localizations': {
            'es': unit('Cola de descargas')}},       # allowed compound
        'Aerials': {'localizations': {'zh-Hant': unit('空拍')}},
        'Add to Library': {'localizations': {'zh-Hant': unit('加入資料庫')}},
        'Steam library': {'localizations': {
            'zh-Hant': unit('Steam 收藏庫')}},       # another library
        'Aerial library': {'localizations': {'zh-Hant': unit('空照圖庫')}},
        'Wallpaper Engine (downloaded)': {'localizations': {
            'zh-Hans': unit('Wallpaper Engine(已下载)')}},  # half-width parens around Chinese
    }}
    terms, punct, ellipsis = copy_audit(copy)
    assert sorted(t[:3] for t in terms) == sorted([
        ('Copy to Other Displays', 'zh-Hans', 'display'),
        ('Workshop', 'zh-Hant', 'workshop'),
        ('Playlist', 'zh-Hant', 'playlist'),
        ('Playlist', 'es', 'playlist'),
        ('MP4 / MOV files and playlists', 'es', 'playlist'),
        ('Aerials', 'zh-Hant', 'aerial'),
        ('Add to Library', 'zh-Hant', 'library'),
    ]), terms
    assert sorted(p[:3] for p in punct) == sorted([
        ('Linked %lld, skipped %lld.', 'zh-Hans', 'halfwidth-punct'),
        ('Wallpaper Engine (downloaded)', 'zh-Hans', 'halfwidth-paren'),
    ]), punct
    assert [e[:2] for e in ellipsis] == [('Connecting…', 'zh-Hans')], ellipsis
    print('Localization drift self-test passed.')


def main():
    if '--self-test' in sys.argv:
        self_test()
        return 0

    catalog = json.loads(CATALOG.read_text())
    mismatch, missing, untranslated = audit(catalog)
    terms, punct, ellipsis = copy_audit(catalog)

    for key, lang, base, found in mismatch:
        print(f'PLACEHOLDER DRIFT  {lang:8} {key[:70]!r}\n'
              f'                   en={base}  {lang}={found}')
    for key, lang in missing:
        print(f'LANGUAGE ABSENT    {lang:8} {key[:70]!r}')
    for key, lang, state in untranslated:
        print(f'NOT TRANSLATED     {lang:8} [{state}] {key[:60]!r}')
    for key, lang, rule, found, use in terms:
        print(f'TERM DRIFT         {lang:8} {key[:70]!r}\n'
              f'                   {rule}: {found!r} -> {use}')
    for key, lang, rule, found, use in punct:
        print(f'PUNCT DRIFT        {lang:8} {key[:70]!r}\n'
              f'                   {rule}: {found!r} -> {use}')
    for key, lang, trails in ellipsis:
        print(f'ELLIPSIS DRIFT     {lang:8} {key[:70]!r}\n'
              f'                   ends with "…": en={trails}  {lang}={not trails}')

    total = (len(mismatch) + len(missing) + len(untranslated)
             + len(terms) + len(punct) + len(ellipsis))
    checked = len(catalog.get('strings', {}))
    if total:
        print(f'\nLocalization drift: {total} problem(s) across {checked} keys.')
        return 1
    print(f'Localization drift: none across {checked} keys.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
