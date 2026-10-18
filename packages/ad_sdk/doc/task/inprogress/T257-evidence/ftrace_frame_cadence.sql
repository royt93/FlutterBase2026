create or replace perfetto table bf as
select s.ts, s.dur from slice s join thread_track tt on s.track_id=tt.id join thread t using(utid) join process p using(upid)
where p.name like '%admobwrapper%' and s.name='Animator::BeginFrame';
create or replace perfetto table gaps as
select ts, dur, ts - lag(ts) over (order by ts) gap from bf;
select count(*) frames, round((max(ts)-min(ts))/1e9,2) span_s,
  round(count(*)/((max(ts)-min(ts))/1e9),1) fps,
  sum(gap>16.7e6) gap_gt_16_7, sum(gap>25e6) gap_gt_25, sum(gap>33.4e6) gap_gt_33_4, sum(gap>50e6) gap_gt_50,
  round(max(gap)/1e6,1) max_gap_ms, round(avg(gap)/1e6,2) avg_gap_ms,
  sum(dur>8.33e6) ui_gt_8_33, sum(dur>16.7e6) ui_gt_16_7
from gaps;
select round(avg(s.dur)/1e6,2) raster_avg, sum(s.dur>8.33e6) raster_gt_8_33, sum(s.dur>16.7e6) raster_gt_16_7, round(max(s.dur)/1e6,1) raster_max
from slice s join thread_track tt on s.track_id=tt.id join thread t using(utid) join process p using(upid)
where p.name like '%admobwrapper%' and s.name='GPURasterizer::Draw';
