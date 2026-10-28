#!/usr/bin/env bash
# Prépare la base « inviteo_web » (vraies migrations) avec un événement publié et 3 invitations,
# puis écrit les jetons dans le fichier passé en argument ($1, JSON).
set -euo pipefail
cd "$(dirname "$0")/../../supabase/tests"
DB=inviteo_web; Q=(psql -X -q -At -v ON_ERROR_STOP=1)
OUT="$1"
"${Q[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB" >/dev/null 2>&1
"${Q[@]}" -d $DB -f 00_supabase_stub.sql >/dev/null 2>&1
for f in ../migrations/*.sql; do "${Q[@]}" -d $DB -f "$f" >/dev/null 2>&1 || { echo "migration KO $f"; exit 1; }; done
ORG='00000000-0000-0000-0000-00000000d001'
"${Q[@]}" -d $DB -c "insert into auth.users (id,email) values ('$ORG','org@web')" >/dev/null
EV=$("${Q[@]}" -d $DB <<SQL | tail -1
begin;
select set_config('request.jwt.claim.sub','$ORG',true);
set local role authenticated;
insert into public.events (organizer_id,event_type,name,starts_at,venue_name,address,maps_url,celebrated_names,message,extra_info,rsvp_enabled,show_qr_on_page,program,template_id)
values ('$ORG','wedding','Mariage Awa & Jean', now()+interval '40 days','Salle Les Jardins','12 avenue de la Paix, Lubumbashi','https://maps.google.com/?q=Lubumbashi',
 'Awa & Jean','Nous serons heureux de partager ce jour avec vous.','Tenue de soirée souhaitée.',true,true,
 '[{"time":"15h00","title":"Cérémonie"},{"time":"18h00","title":"Cocktail"},{"time":"20h00","title":"Dîner"}]'::jsonb,
 (select id from public.templates where slug='mariage-classique')) returning id;
commit;
SQL
)
"${Q[@]}" -d $DB -c "begin; select set_config('request.jwt.claim.sub','$ORG',true); set local role authenticated; update public.events set status='published' where id='$EV'; commit;" >/dev/null
inv() { "${Q[@]}" -d $DB <<SQL | tail -1
begin;
select set_config('request.jwt.claim.sub','$ORG',true);
set local role authenticated;
with g as (insert into public.guests (event_id,full_name,party_size) values ('$EV','$1',$2) returning id)
select view_token || '|' || qr_token || '|' || invitation_id from g, lateral public.issue_invitation(g.id);
commit;
SQL
}
A=$(inv "Marie <b>Kabila</b> O''Neil" 2); B=$(inv "Patrick Mwamba" 1); C=$(inv "Révoquée Test" 1)
RID=${C##*|}
AG1='00000000-0000-0000-0000-00000000a001'; AG2='00000000-0000-0000-0000-00000000a002'
"${Q[@]}" -d $DB <<SQL >/dev/null
insert into auth.users (id,email) values ('$AG1','agent1@web'),('$AG2','agent2@web');
update public.profiles set role='agent', created_by='$ORG', full_name='Agent Un' where id='$AG1';
update public.profiles set role='agent', created_by='$ORG', full_name='Agent Deux' where id='$AG2';
SQL
"${Q[@]}" -d $DB -c "begin; select set_config('request.jwt.claim.sub','$ORG',true); set local role authenticated; insert into public.event_staff (event_id,agent_id) values ('$EV','$AG1'); commit;" >/dev/null
ORG2='00000000-0000-0000-0000-00000000d002'
"${Q[@]}" -d $DB -c "insert into auth.users (id,email) values ('$ORG2','org2@web')" >/dev/null
GID=$("${Q[@]}" -d $DB <<SQL | tail -1
begin;
select set_config('request.jwt.claim.sub','$ORG',true);
set local role authenticated;
insert into public.guests (event_id,full_name,party_size) values ('$EV','Élodie Ngoy-Kalonji wa Mwamba Tshisekedi',3) returning id;
commit;
SQL
)
"${Q[@]}" -d $DB -c "begin; select set_config('request.jwt.claim.sub','$ORG',true); set local role authenticated; select public.revoke_invitation('$RID'); commit;" >/dev/null
EV2=$("${Q[@]}" -d $DB <<SQL | tail -1
begin;
select set_config('request.jwt.claim.sub','$ORG2',true);
set local role authenticated;
insert into public.events (organizer_id,event_type,name,starts_at,venue_name,celebrated_names,template_id)
values ('$ORG2','birthday','Autre fête',now()+interval '5 days','Salon','Test',(select id from public.templates where slug='anniversaire-elegant')) returning id;
commit;
SQL
)
"${Q[@]}" -d $DB -c "begin; select set_config('request.jwt.claim.sub','$ORG2',true); set local role authenticated; update public.events set status='published' where id='$EV2'; commit;" >/dev/null
OTH=$("${Q[@]}" -d $DB <<SQL | tail -1
begin;
select set_config('request.jwt.claim.sub','$ORG2',true);
set local role authenticated;
with g as (insert into public.guests (event_id,full_name,party_size) values ('$EV2','Autre Invité',1) returning id)
select view_token || '|' || qr_token || '|' || invitation_id from g, lateral public.issue_invitation(g.id);
commit;
SQL
)
python3 - "$OUT" "$EV" "$A" "$B" "$C" "$GID" "$OTH" "$AG1" "$AG2" "$EV2" <<'PY'
import json,sys
o,ev,a,b,c,gid,oth,ag1,ag2,ev2=sys.argv[1:]
f=lambda s:dict(zip(('view','qr','id'),s.split('|')))
json.dump({'org':'00000000-0000-0000-0000-00000000d001','org2':'00000000-0000-0000-0000-00000000d002','guest':gid,'other':f(oth),'event2':ev2,'agent':{'id':ag1,'email':'agent1@web'},'agent2':{'id':ag2,'email':'agent2@web'},'event':ev,'a':f(a),'b':f(b),'revoked':f(c),'other':f(oth)},open(o,'w'))
PY
echo "fixture prête"
