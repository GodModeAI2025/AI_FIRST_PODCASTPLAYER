"""Smart-feed policy/fixture tests; no Apple runtime, real audio or model calls."""
from __future__ import annotations
import unittest, copy, sys
from pathlib import Path
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'scripts'))
from packet_checks import PacketError, load
from smart_feed_checks import (canonical_hash, episode_batch_key, union_ranges, subtract_ranges,
    heard_ranges, unseen_segment_ids, source_position, cover_action, validate_cover, validate_personal_episode)

class SmartFeedTests(unittest.TestCase):
    def setUp(self):
        p=ROOT/'fixtures/smart-feed'
        self.feed=load(p/'feed.json');self.ep=load(p/'personal-episode.json');self.before=load(p/'ledger-before.json');self.after=load(p/'ledger-after.json')
        self.cover=load(p/'cover-native.json');self.confirmed=load(p/'cover-confirmed-contract-only.json');self.corpus=load(ROOT/'fixtures/corpus.json')
    def rehash(self):
        self.ep['manifestHash']=canonical_hash(self.ep['segments'])
        self.ep['batchKey']=episode_batch_key(self.feed['id'],self.ep['policyRevision'],self.ep['segments'])
    def check(self):validate_personal_episode(self.ep,self.feed,self.corpus)
    def bad(self,fn,*args):
        with self.assertRaises(PacketError):fn(*args)
    def test_personal_episode_valid(self): self.check()
    def test_batch_independent_of_title_and_date(self):
        old=self.ep['batchKey'];self.ep['title']='Anderer Titel';self.ep['publishedAt']='2026-09-21T00:00:00Z';self.check();self.assertEqual(old,self.ep['batchKey'])
    def test_batch_same_for_candidate_order(self):self.assertEqual(self.ep['batchKey'],episode_batch_key(self.feed['id'],1,list(reversed(self.ep['segments']))))
    def test_manifest_change_rejected(self):self.ep['segments'][0]['reason']='unconfirmed';self.bad(self.check)
    def test_empty_episode_rejected(self):self.ep['segments']=[];self.rehash();self.bad(self.check)
    def test_timeline_gap_rejected(self):self.ep['segments'][1]['virtualRange']['startMs']+=1;self.rehash();self.bad(self.check)
    def test_duration_fabrication_rejected(self):self.ep['totalMediaMs']+=1000;self.bad(self.check)
    def test_wrong_media_rejected(self):self.ep['segments'][0]['mediaVersionID']='media-4';self.rehash();self.bad(self.check)
    def test_wrong_scope_rejected(self):self.feed['sourceEpisodeIDs']=['episode-1'];self.bad(self.check)
    def test_unreferenced_shownote_rejected(self):self.ep['shownotes'][0]['evidenceIDs']=['ev-4-0'];self.bad(self.check)
    def test_included_count_exact(self):self.ep['coverage']['includedEpisodes']=3;self.bad(self.check)
    def test_original_only(self):self.ep['audioPolicy']='syntheticNarration';self.bad(self.check)
    def test_original_position_second_clip(self):self.assertEqual(source_position(self.ep,70000),('media-2',30000))
    def test_boundary_maps_to_next(self):self.assertEqual(source_position(self.ep,65000),('media-2',25000))
    def test_time_outside_episode_rejected(self):self.bad(source_position,self.ep,110000)
    def test_new_before_listening(self):self.assertEqual(unseen_segment_ids(self.ep,self.before),['clip-1','clip-2'])
    def test_seek_not_listening(self):self.assertEqual(unseen_segment_ids(self.ep,self.after),['clip-2'])
    def test_nonplay_events_never_heard(self):
        for kind in ['seek','paused','buffering','downloaded','analyzed','shownotesRead','markedDone']:
            with self.subTest(kind=kind):
                d=copy.deepcopy(self.after);d['events'][0]['eventKind']=kind;self.assertEqual(heard_ranges(d,'media-1'),[])
    def test_union_does_not_double_count(self):self.assertEqual(union_ranges([{'startMs':10,'endMs':20},{'startMs':15,'endMs':25}]),[{'startMs':10,'endMs':25}])
    def test_disjoint_ranges_keep_seek_gap(self):self.assertEqual(union_ranges([{'startMs':10,'endMs':20},{'startMs':60,'endMs':65}]),[{'startMs':10,'endMs':20},{'startMs':60,'endMs':65}])
    def test_partial_core_retained(self):self.assertEqual(subtract_ranges({'startMs':10,'endMs':30},[{'startMs':10,'endMs':20}]),[{'startMs':20,'endMs':30}])
    def test_same_recording_different_revision_not_merged(self):self.assertEqual(heard_ranges(self.after,'media-1-new-version'),[])
    def test_history_reset_excludes_old_events(self):self.after['epoch']=2;self.assertEqual(heard_ranges(self.after,'media-1'),[])
    def test_duplicate_event_idempotent(self):self.after['events'].append(copy.deepcopy(self.after['events'][0]));self.assertEqual(heard_ranges(self.after,'media-1'),[{'startMs':5000,'endMs':70000}])
    def test_conflicting_event_payload_rejected(self):
        d=copy.deepcopy(self.after['events'][0]);d['range']['endMs']=68000;self.after['events'].append(d);self.bad(heard_ranges,self.after,'media-1')
    def test_native_cover_valid(self):validate_cover(self.cover)
    def test_confirmed_cover_valid(self):validate_cover(self.confirmed)
    def test_cover_needs_user_confirmation(self):self.confirmed['userConfirmed']=False;self.bad(validate_cover,self.confirmed)
    def test_external_cover_provider_rejected(self):self.confirmed['externalProvider']=True;self.bad(validate_cover,self.confirmed)
    def test_unsafe_cover_path_rejected(self):self.confirmed['assetRelativePath']='../private/secret';self.bad(validate_cover,self.confirmed)
    def test_no_background_image_sheet(self):self.assertEqual(cover_action(supported=True,user_tapped=False),'nativeTemplate')
    def test_user_action_starts_sheet(self):self.assertEqual(cover_action(supported=True,user_tapped=True),'presentSystemSheet')
    def test_unsupported_keeps_native_cover(self):self.assertEqual(cover_action(supported=False,user_tapped=True),'nativeTemplate')
