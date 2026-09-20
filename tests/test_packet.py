"""Deterministic tests of specification/fixture invariants, NOT product app tests."""
from __future__ import annotations
import copy
import sys
import unittest
from pathlib import Path
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/"scripts"))
from packet_checks import (PacketError, load, validate_packet, validate_schema, validate_corpus,
    validate_plan, plan_hash, validate_grant, validate_answer, validate_archive, validate_stance,
    validate_counterpoint, validate_graph, validate_closure, session_transition, task_order, safe_relative)

class PacketInvariantTests(unittest.TestCase):
    def setUp(self) -> None:
        self.corpus = load(ROOT/"fixtures/corpus.json")
        self.plan = load(ROOT/"fixtures/valid/plan.json")
        self.grant = load(ROOT/"fixtures/valid/grant.json")
        self.stance = load(ROOT/"fixtures/valid/stance.json")
        self.graph = load(ROOT/"fixtures/valid/graph.json")
        self.closure = load(ROOT/"fixtures/valid/session-closure.json")
        self.catalog = load(ROOT/"fixtures/source-catalog.json")
    def rehash(self) -> None: self.plan["planHash"] = plan_hash(self.plan)
    def assertBad(self, fn, *args, **kw) -> None:
        with self.assertRaises(PacketError): fn(*args, **kw)
    def checkGrant(self) -> None:
        validate_grant(self.grant, self.plan, device="device-demo",session="session-demo",now=2000,consent_revision=1)
    def checkClosure(self) -> None: validate_closure(self.closure,self.corpus,self.catalog,self.graph)

    def test_01_packet_is_consistent(self):
        r = validate_packet(ROOT, verify_manifest=False)
        self.assertEqual((r["requirements"],r["stories"],r["tasks"]), (144,20,266))
        self.assertFalse(r["appleAppBuilt"])
    def test_02_boolean_is_not_integer(self):
        self.assertBad(validate_schema, True, {"type":"integer"})
    def test_03_const_false_is_not_zero(self):
        self.assertBad(validate_schema, 0, {"const":False})
    def test_04_schema_unknown_field_rejected(self):
        s=load(ROOT/"specs/001-ai-podcast-player/contracts/stance.schema.json")
        self.stance["secretUpload"]="https://example.invalid"
        self.assertBad(validate_schema,self.stance,s)
    def test_05_corpus_good(self): validate_corpus(self.corpus)
    def test_06_invented_evidence_quote_rejected(self):
        self.corpus["evidence"][0]["excerpt"]="Nicht im Original enthalten"
        self.assertBad(validate_corpus,self.corpus)
    def test_07_invented_segment_rejected(self):
        self.corpus["evidence"][0]["segmentIDs"]=["invented"]
        self.assertBad(validate_corpus,self.corpus)
    def test_08_wrong_media_revision_rejected(self):
        self.corpus["evidence"][0]["mediaVersionID"]="media-2"
        self.assertBad(validate_corpus,self.corpus)
    def test_09_zero_length_time_rejected(self):
        self.corpus["transcripts"][0]["segments"][0]["range"]["endMs"]=10000
        self.assertBad(validate_corpus,self.corpus)
    def test_10_provisional_transcript_not_verified(self):
        self.corpus["transcripts"][0]["segments"][0]["final"]=False
        self.assertBad(validate_corpus,self.corpus)
    def test_11_word_outside_segment_rejected(self):
        self.corpus["transcripts"][0]["segments"][0]["words"]=[{"text":"Ein","range":{"startMs":0,"endMs":5000}}]
        self.assertBad(validate_corpus,self.corpus)
    def test_12_unheard_can_be_analyzed(self):
        validate_corpus(self.corpus)
        self.assertEqual(self.corpus["playedEpisodeIDs"],[])
        self.assertEqual(len(self.corpus["analyzedEpisodeIDs"]),4)
    def test_13_plan_good(self): validate_plan(self.plan,self.corpus)
    def test_14_plan_tamper_rejected(self):
        self.plan["segments"][0]["reason"]="changed without renewed hash"
        self.assertBad(validate_plan,self.plan,self.corpus)
    def test_15_over_budget_rejected(self):
        self.plan["activeListeningBudgetMs"]=100;self.rehash()
        self.assertBad(validate_plan,self.plan,self.corpus)
    def test_16_plan_invented_evidence_rejected(self):
        self.plan["segments"][0]["evidenceIDs"]=["not-a-source"];self.rehash()
        self.assertBad(validate_plan,self.plan,self.corpus)
    def test_17_plan_wrong_version_rejected(self):
        self.plan["segments"][0]["transcriptRevisionID"]="transcript-2";self.rehash()
        self.assertBad(validate_plan,self.plan,self.corpus)
    def test_18_core_outside_playback_rejected(self):
        self.plan["segments"][0]["coreRange"]={"startMs":90000,"endMs":100000};self.rehash()
        self.assertBad(validate_plan,self.plan,self.corpus)
    def test_19_audio_capability_required(self):
        self.corpus["media"][0]["capabilities"]["nativeAudio"]=False
        self.assertBad(validate_plan,self.plan,self.corpus)
    def test_20_provisional_media_not_startable(self):
        self.corpus["media"][0]["identityStatus"]="provisional"
        self.assertBad(validate_plan,self.plan,self.corpus)
    def test_21_speed_changes_require_duration_and_grant(self):
        self.plan["playbackRate"]=2;self.rehash()
        self.assertBad(validate_plan,self.plan,self.corpus)
        self.plan["estimatedListeningMs"]=56000;self.rehash();validate_plan(self.plan,self.corpus)
        self.assertBad(self.checkGrant)
    def test_22_grant_good(self): self.checkGrant()
    def test_23_grant_wrong_device(self):
        self.grant["deviceID"]="other";self.assertBad(self.checkGrant)
    def test_24_grant_wrong_session(self):
        self.grant["sessionID"]="other";self.assertBad(self.checkGrant)
    def test_25_grant_expired(self):
        self.grant["expiresAtEpochMs"]=2000;self.assertBad(self.checkGrant)
    def test_26_grant_consumed(self):
        self.grant["consumed"]=True;self.assertBad(self.checkGrant)
    def test_27_grant_stale_consent(self):
        self.grant["consentRevision"]=0;self.assertBad(self.checkGrant)
    def test_28_implicit_autoplay_is_not_grant(self):
        self.grant["kind"]="recommendation";self.assertBad(self.checkGrant)
    def test_29_answer_scope_rejected(self):
        a=load(ROOT/"fixtures/valid/answer.json");a["selectedEpisodeIDs"]=[]
        self.assertBad(validate_answer,a,self.corpus)
    def test_30_answer_false_coverage_rejected(self):
        a=load(ROOT/"fixtures/valid/answer.json");a["usedEpisodeIDs"].append("episode-2")
        self.assertBad(validate_answer,a,self.corpus)
    def test_31_archive_found_is_not_analyzed(self):
        a=load(ROOT/"fixtures/valid/archive.json");validate_archive(a)
        self.assertEqual((a["discoveredCount"],a["analyzableCount"],a["analyzedCount"]),(120,75,20))
    def test_32_archive_false_completion_rejected(self):
        a=load(ROOT/"fixtures/valid/archive.json");a["analysisState"]="complete"
        self.assertBad(validate_archive,a)
    def test_33_archive_duplicate_selection_rejected(self):
        a=load(ROOT/"fixtures/valid/archive.json");a["selectedEpisodeIDs"].append(a["selectedEpisodeIDs"][0])
        self.assertBad(validate_archive,a)
    def test_34_stance_requires_explicit_confirmation(self):
        self.stance["origin"]="modelSuggestion";self.assertBad(validate_stance,self.stance)
    def test_35_proposed_ordinary_stance_is_not_confirmed(self):
        self.stance["status"]="proposed";self.stance["origin"]="modelSuggestion"
        validate_stance(self.stance)
    def test_36_political_belief_inference_rejected(self):
        self.stance.update(status="proposed",origin="modelSuggestion",sensitivity="political")
        self.assertBad(validate_stance,self.stance)
    def test_37_counterpoint_fixture_good(self):
        validate_counterpoint(load(ROOT/"fixtures/valid/counterpoint.json"),self.stance,self.corpus)
    def test_38_political_personalized_mixer_rejected(self):
        self.stance["sensitivity"]="political"
        self.assertBad(validate_counterpoint,load(ROOT/"fixtures/valid/counterpoint.json"),self.stance,self.corpus)
    def test_39_explicit_neutral_comparison_allowed(self):
        self.stance["sensitivity"]="political";c=load(ROOT/"fixtures/valid/counterpoint.json");c["mode"]="neutralComparison"
        validate_counterpoint(c,self.stance,self.corpus)
    def test_40_changed_stance_invalidates_prepared_mix(self):
        self.stance["revision"]=2
        self.assertBad(validate_counterpoint,load(ROOT/"fixtures/valid/counterpoint.json"),self.stance,self.corpus)
    def test_41_no_evidence_does_not_produce_plan(self):
        c=load(ROOT/"fixtures/valid/counterpoint.json");c["state"]="noEvidence";c["relations"]=[]
        self.assertBad(validate_counterpoint,c,self.stance,self.corpus)
    def test_42_graph_good(self): validate_graph(self.graph,self.corpus)
    def test_43_dangling_edge_rejected(self):
        self.graph["edges"][0]["toID"]="missing";self.assertBad(validate_graph,self.graph,self.corpus)
    def test_44_out_of_scope_graph_evidence_rejected(self):
        self.graph["scopeEpisodeIDs"]=["episode-1"];self.assertBad(validate_graph,self.graph,self.corpus)
    def test_45_source_claim_needs_evidence(self):
        self.graph["nodes"][2]["evidenceIDs"]=[];self.assertBad(validate_graph,self.graph,self.corpus)
    def test_46_model_relation_not_truth_certificate(self):
        self.graph["edges"][-1]["reviewStatus"]="systemVerified";self.assertBad(validate_graph,self.graph,self.corpus)
    def test_47_closure_four_verified_sources(self): self.checkClosure()
    def test_48_invented_source_count_rejected(self):
        self.closure["uniqueSourceCount"]=5;self.assertBad(self.checkClosure)
    def test_49_syndicated_source_not_counted_twice(self):
        self.catalog["entries"][1]["originalRecordingID"]="recording-1"
        self.assertBad(self.checkClosure)
        self.closure["uniqueSourceCount"]=3;self.checkClosure()
    def test_50_unavailable_followup_source_rejected(self):
        self.catalog["entries"][0]["available"]=False;self.assertBad(self.checkClosure)
    def test_51_endless_autoplay_rejected(self):
        self.closure["startNextAutomatically"]=True;self.assertBad(self.checkClosure)
    def test_52_pause_does_not_close_session(self):
        self.assertEqual(session_transition("running","pause"),"paused")
        self.assertEqual(session_transition("running","headphonesDisconnected"),"paused")
        self.assertEqual(session_transition("running","sleepTimer"),"paused")
    def test_53_budget_end_offers_closure(self):
        self.assertEqual(session_transition("running","budgetEnd"),"closing")
        self.assertEqual(session_transition("closing","dismiss"),"closed")
    def test_54_interruption_not_a_forced_decision(self):
        self.closure["reason"]="interrupted";self.assertBad(self.checkClosure)
        self.closure["state"]="paused";self.checkClosure()
    def test_55_export_without_parking_rejected(self):
        self.closure["exportState"]="exported";self.assertBad(self.checkClosure)
    def test_56_duplicate_graph_node_rejected(self):
        self.graph["nodes"].append(copy.deepcopy(self.graph["nodes"][0]));self.assertBad(validate_graph,self.graph,self.corpus)
    def test_57_task_cycle_rejected(self):
        self.assertBad(task_order,[{"id":"T1","dependsOn":["T2"]},{"id":"T2","dependsOn":["T1"]}])
    def test_58_missing_task_rejected(self):
        self.assertBad(task_order,[{"id":"T1","dependsOn":["unknown"]}])
    def test_59_task_order_is_topological(self):
        self.assertEqual(task_order([{"id":"T2","dependsOn":["T1"]},{"id":"T1","dependsOn":[]}]),["T1","T2"])
    def test_60_packet_path_traversal_rejected(self):
        self.assertBad(safe_relative,ROOT,"../outside")
    def test_61_unsupported_schema_not_silently_ignored(self):
        self.assertBad(validate_schema,"anything",{"customUnknownKeyword":True})
    def test_62_export_does_not_implicitly_include_private_notes(self):
        self.assertFalse(self.graph["includesPrivateNotes"])
        self.assertTrue(all(n["kind"]!="note" for n in self.graph["nodes"]))

if __name__ == "__main__":
    unittest.main(verbosity=2)
