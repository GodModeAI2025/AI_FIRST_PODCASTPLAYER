"""Deterministic specification checks, not production Swift implementation."""
from __future__ import annotations
import hashlib
import json
from typing import Any
from packet_checks import require, check_range, includes, by_id, validate_plan, plan_hash, load

def canonical_hash(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode()).hexdigest()

def episode_batch_key(feed_id: str, policy: int, segments: list[dict]) -> str:
    keys = sorted((s['episodeID'], s['mediaVersionID'], s['transcriptRevisionID'],
                   tuple(sorted(s['evidenceIDs'])), s['coreRange']['startMs'], s['coreRange']['endMs']) for s in segments)
    return canonical_hash([feed_id, policy, keys])

def union_ranges(ranges: list[dict]) -> list[dict]:
    for r in ranges: check_range(r)
    result: list[dict] = []
    for r in sorted(ranges, key=lambda x: (x['startMs'], x['endMs'])):
        if result and r['startMs'] <= result[-1]['endMs']:
            result[-1]['endMs'] = max(result[-1]['endMs'], r['endMs'])
        else:
            result.append(dict(r))
    return result

def subtract_ranges(core: dict, covered: list[dict]) -> list[dict]:
    """Interval arithmetic only; safe sentence alignment is a separate product gate."""
    check_range(core)
    cursor = core['startMs']; result = []
    for r in union_ranges(covered):
        if r['endMs'] <= cursor or r['startMs'] >= core['endMs']: continue
        if r['startMs'] > cursor:
            result.append({'startMs':cursor, 'endMs':min(r['startMs'],core['endMs'])})
        cursor = min(core['endMs'], max(cursor, r['endMs']))
    if cursor < core['endMs']:result.append({'startMs':cursor, 'endMs':core['endMs']})
    return result

def heard_ranges(ledger: dict, media_id: str) -> list[dict]:
    active = {}
    for event in ledger['events']:
        if event['epoch'] != ledger['epoch']: continue
        if event['id'] in active:
            require(active[event['id']] == event, 'ledger: conflicting event payload')
        active[event['id']] = event
    return union_ranges([e['range'] for e in active.values()
                         if e['eventKind'] == 'played' and e['mediaVersionID'] == media_id])

def unseen_segment_ids(episode: dict, ledger: dict) -> list[str]:
    return [s['id'] for s in episode['segments'] if subtract_ranges(s['coreRange'], heard_ranges(ledger,s['mediaVersionID']))]

def source_position(episode: dict, virtual_ms: int) -> tuple[str, int]:
    require(type(virtual_ms) is int and 0 <= virtual_ms < episode['totalMediaMs'], 'timeline: out of bounds')
    for s in episode['segments']:
        if s['virtualRange']['startMs'] <= virtual_ms < s['virtualRange']['endMs']:
            return (s['mediaVersionID'], s['playbackRange']['startMs']+virtual_ms-s['virtualRange']['startMs'])
    raise ValueError('timeline: gap')

def cover_action(*, supported: bool, user_tapped: bool) -> str:
    return 'presentSystemSheet' if supported and user_tapped else 'nativeTemplate'

def validate_cover(cover: dict) -> None:
    require(cover['externalProvider'] is False, 'cover: external provider prohibited')
    if cover['origin'] == 'nativeTemplate':
        require(cover['provider'] == 'none' and cover['state'] == 'templateReady', 'cover: template misrepresented as AI')
        require(bool(cover.get('templateID')), 'cover: missing native template')
    if cover['origin'] == 'userConfirmedImagePlayground':
        require(cover['provider'] == 'apple', 'cover: Apple-only required')
        require(cover['userConfirmed'] is True and cover['state'] == 'persisted', 'cover: missing user confirmation or persistence')
        require(bool(cover.get('assetRelativePath')) and len(cover.get('sha256','')) == 64, 'cover: missing persisted asset metadata')
    if 'assetRelativePath' in cover:
        from pathlib import PurePosixPath
        p=PurePosixPath(cover['assetRelativePath'])
        require(not p.is_absolute() and '..' not in p.parts, 'cover: unsafe path')

def validate_personal_episode(episode: dict, feed: dict, corpus: dict) -> None:
    require(episode['feedID'] == feed['id'], 'personal episode: wrong feed')
    require(episode['audioPolicy'] == 'originalOnly', 'personal episode: synthesized audio prohibited')
    require(episode['manifestHash'] == canonical_hash(episode['segments']), 'personal episode: manifest changed')
    require(episode['batchKey'] == episode_batch_key(feed['id'],episode['policyRevision'],episode['segments']), 'personal episode: batch mismatch')
    require(bool(episode['segments']), 'personal episode: empty')
    require(episode['policyRevision'] == feed['policyRevision'], 'personal episode: wrong policy')
    scope = set(feed['sourceEpisodeIDs']); cursor=0; evidence=set(); selected=set()
    for s in episode['segments']:
        require(s['episodeID'] in scope, 'personal episode: out-of-scope source')
        require(set(s['topicIDs']) <= set(feed['topicIDs']), 'personal episode: out-of-scope topic')
        check_range(s['virtualRange'])
        require(s['virtualRange']['startMs'] == cursor, 'personal episode: gap/overlap')
        length=s['playbackRange']['endMs']-s['playbackRange']['startMs']
        require(s['virtualRange']['endMs']-s['virtualRange']['startMs'] == length, 'personal episode: time stretch')
        cursor = s['virtualRange']['endMs'];evidence.update(s['evidenceIDs']);selected.add(s['episodeID'])
    require(cursor == episode['totalMediaMs'], 'personal episode: wrong duration')
    coverage=episode['coverage']
    require(coverage['includedEpisodes'] == len(selected), 'personal episode: incorrect included count')
    require(0 <= coverage['includedEpisodes'] <= coverage['analyzedEpisodes'] <= coverage['discoveredEpisodes'], 'personal episode: invalid coverage counts')
    require(coverage['remainingMatchedSegments'] >= 0, 'personal episode: invalid remainder')
    for note in episode['shownotes']:
        require(bool(note['evidenceIDs']) and set(note['evidenceIDs']) <= evidence, 'shownotes: out-of-manifest citations')
    converted=[]
    for s in episode['segments']:
        converted.append({k:v for k,v in s.items() if k not in {'virtualRange','topicIDs','contextReplay'}})
    plan={'schemaVersion':1,'id':episode['id'],'revision':episode['revision'],'scopeDigest':'synthetic-smart-feed',
          'segments':converted,'activeListeningBudgetMs':cursor,'playbackRate':1.0,'transitionMs':0,'estimatedListeningMs':cursor}
    plan['planHash']=plan_hash(plan);validate_plan(plan,corpus)

def validate_smart_feed_fixtures(root, corpus) -> None:
    folder=root/'fixtures/smart-feed'
    feed=load(folder/'feed.json');ep=load(folder/'personal-episode.json')
    validate_personal_episode(ep,feed,corpus)
    before=load(folder/'ledger-before.json');after=load(folder/'ledger-after.json')
    require(unseen_segment_ids(ep,before) == ['clip-1','clip-2'], 'ledger: incorrect baseline')
    require(unseen_segment_ids(ep,after) == ['clip-2'], 'ledger: seek was counted as listening')
    validate_cover(load(folder/'cover-native.json'))
    validate_cover(load(folder/'cover-confirmed-contract-only.json'))
