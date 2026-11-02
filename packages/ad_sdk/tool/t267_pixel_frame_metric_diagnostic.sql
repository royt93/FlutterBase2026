SELECT
  p.pid,
  p.name AS process_name,
  t.tid,
  t.name AS thread_name,
  SUM(s.name LIKE 'AChoreographer_frameCallback64%') AS ndk_frame_callbacks,
  SUM(s.name LIKE 'Choreographer#doFrame%') AS java_do_frame,
  SUM(s.name LIKE 'DrawFrame%') AS hwui_draw_frame,
  SUM(s.name LIKE 'QueuePresentKHR%') AS queue_present,
  COUNT(*) AS total_slices
FROM slice s
JOIN thread_track tt ON s.track_id = tt.id
JOIN thread t USING (utid)
JOIN process p USING (upid)
WHERE p.name = 'com.roy.admobwrapper.benchmark'
  AND (
    s.name LIKE 'AChoreographer_frameCallback64%'
    OR s.name LIKE 'Choreographer#doFrame%'
    OR s.name LIKE 'DrawFrame%'
    OR s.name LIKE 'QueuePresentKHR%'
  )
GROUP BY p.pid, p.name, t.tid, t.name
ORDER BY total_slices DESC;
