-- active users
select `name`,'from where',case when enabled=1 then 'yes' else 'no' end as state from `user`;
