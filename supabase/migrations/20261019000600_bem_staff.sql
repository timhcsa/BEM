-- =====================================================================
-- BEM Ledger — BEM's staff missionaries (from barnabasenrichmentministries.org/staff)
-- Each gets a missionary account (fund) with the standard admin fee.
-- Photos are served by the app from /public/staff/.
-- Safe to re-run: existing missionaries (matched by fund code or name) are
-- left alone, except that a missing photo or bio is filled in.
-- =====================================================================
do $$
declare r record; v_id uuid;
begin
  for r in select * from (values
    ('Tim & Sandy Hewitt', 'Co-Founders', 'M-HEWITT', '/staff/tim-sandy-hewitt.jpg', 1, 'Tim received the call from God to full time vocational ministry as a working professional (Electrical Engineer) and young father. He graduated from Grace Theological Seminary in Winona Lake Indiana in 1995 and, shortly thereafter, accepted the position of Senior Pastor at a small Independent Baptist Church in Elkhart Indiana. Tim served at Calvary Baptist Church for 12 years, three of those years having been bi-vocational as Engineer and Pastor. Through firsthand experience, the Hewitt''s know both the challenges and rewards of working ''solo'' in the ministry of the small local church.'),
    ('John & Beabea Rogers', 'Field Director & Missionaries', 'M-ROGERS', '/staff/john-beabea-rogers.jpg', 2, 'In December of 2000 the Rogers family moved to Indiana where John became Pre-Field Director for Evangelical Baptist Missions (2000-2008) and Regional Coordinator for North America (2009-2011). In addition to working with missionary appointees in their pre-field process, he and Beabea spent time assisting Bible believing churches in their efforts to develop their people for missions as well as teaching how to both witness for Jesus Christ and live their faith before others.'),
    ('Philip & Katie Hewitt', 'Technical Advisor', 'M-PHEWITT', '/staff/philip-katie-hewitt.jpg', 3, 'Philip and Katie met as teenagers in their church''s youth group, dated for 2 years and were married in 2005. They have served faithfully in many areas of their local church since that time. They have four children, who Katie homeschools. She also actively serves in their homeschool co-op. Having trained in the field of IT, Philip has worked in that capacity for the past 14+ years.'),
    ('Jim & Jeanne Keller', 'Midwest Field Director', 'M-KELLER', '/staff/jim-jeanne-keller.jpg', 4, 'Jim and Jeanne Keller have been involved in ministry for over 40 years. Jim has served as a pastor in three churches including 30 years at Bethel Baptist Church in Topeka, Kansas. In his early years, Jim was the campus pastor for a Christian School in South Dakota. Jim has also served as an adjunct professor for a Bible college and teaches overseas in pastoral training.'),
    ('Chris & Rachel DeMorell', 'Western Field Director', 'M-DEMORELL', '/staff/chris-rachel-demorell.jpg', 5, 'Chris DeMorell grew up in northern New Jersey in a non-practicing Catholic household. He attended Ohio State University after high school and was immediately involved in the fraternity party scene. It was between his sophomore and junior years that God began to work in his heart. Having very little Bible understanding he began reading a Gideon NT.'),
    ('Ted & Marlene Sutherland', 'Missionaries', 'M-SUTHERLAND', '/staff/ted-marlene-sutherland.jpg', 6, 'Ted and Marlene first met in 1970 while attending a Christian high school. Both were blessed to be raised in strong, God-centered Christian homes. During his high school years, Ted sensed God''s call to ministry. The couple married in 1976, and Ted later graduated from MBBC in 1983.')
  ) as s(display_name, role_title, fund_code, photo_url, sort, bio)
  loop
    select m.id into v_id from missionaries m join funds f on f.id = m.fund_id
     where f.code = r.fund_code or lower(m.display_name) = lower(r.display_name)
     limit 1;
    if v_id is null then
      perform save_missionary(jsonb_build_object('display_name', r.display_name, 'role_title', r.role_title,
        'fund_code', r.fund_code, 'photo_url', r.photo_url, 'sort', r.sort, 'bio', r.bio));
    else
      update missionaries set
        photo_url = case when photo_url is null or photo_url like '%base44.com%' then r.photo_url else photo_url end,
        bio = coalesce(bio, r.bio),
        role_title = coalesce(role_title, r.role_title)
      where id = v_id;
    end if;
  end loop;
end $$;

-- The Triage Fund (Pastor Network Initiative), named on the BEM website.
insert into funds (code, name, kind, restriction, admin_fee_applies, sort, description)
values ('TRIAGE', 'The Triage Fund', 'other', 'with', false, 3, 'Pastor Network Initiative - help for churches in need')
on conflict (code) do nothing;
