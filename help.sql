/*
 * АДМИНИСТРИРОВАНИЕ И КОНФИГИ
 */

/*** ОБЩИЕ ЗАПРОСЫ ***/
SELECT current_setting('data_directory')||'/'||pg_current_logfile() -- Путь до текущего файла лога
SELECT current_setting('version');  -- Версия PostgreSQL эквивалентно SHOW version;
SELECT current_setting('config_file'); -- Путь к конфигам эквивалентно SHOW config_file;
SELECT current_setting('data_directory'); -- Путь к данным эквивалентно SHOW data_directory;

/*** ЧИТАТЬ ЛОГИ ***/
SELECT 
current_setting('data_directory')||'/'||pg_current_logfile(),
pg_read_file(current_setting('data_directory')||'/'||pg_current_logfile(), 0, 10000)

/*** ПРОЧИТАТЬ КОНФИГ ***/  -- эквивалентно nano postgresql.conf в data директории
SELECT * FROM pg_settings;

/*** ПЕРЕЧИТАТЬ КОНФИГ ***/
SELECT pg_reload_conf();

/*
 * Изменить конфиг можно
 * ALTER SYSTEM SET maintenance_work_mem = '4GB'; (TODO) расписать
 * ALTER SYSTEM SET work_mem = '16Mb';  (Важно!) слишком низкое значение увеличит нагрузку на пропускную способность диска, слишком высокое увеличит кол-во потребляемой памяти, что вызовет падения от OOM Killer (Out-Of-Memory Killer)  
 */

SELECT name,pg_size_pretty(setting::bigint), unit FROM pg_settings where name in ('shared_buffers','maintenance_work_mem','work_mem');

SHOW work_mem;


SELECT name, setting, unit, context 
FROM pg_settings 
WHERE name IN (
    'work_mem', 
    'maintenance_work_mem',
    'autovacuum_work_mem',
    'max_stack_depth',
    'max_connections',
    'superuser_reserved_connections',
        'temp_buffers',           -- временные буферы на сессию
    'wal_buffers',            -- WAL буферы
    'logical_decoding_work_mem' -- логическая репликация
);


-- Если ты вручную что-то в конфиге навертел (json спаси твою душу), проверь нужно ли ребутать постгер
WITH settings_source AS (
    SELECT 
        name,
        setting,
        source,
        sourcefile,
        sourceline,
        pending_restart
    FROM pg_settings
    WHERE name = 'work_mem'
)
SELECT 
    'Текущее значение: ' || setting || ' из источника: ' || source as info,
    CASE 
        WHEN sourcefile IS NOT NULL THEN 'Файл: ' || sourcefile || ':' || sourceline
        ELSE 'Нет файла'
    END as location,
    CASE pending_restart
        WHEN true THEN '⚠️ Требуется перезапуск PostgreSQL'
        ELSE ' Не требует перезапуска'
    END as restart_needed
FROM settings_source;


/* МОНИТОРИНГ */
-- быстрый просмотр статистики по сессиям
SELECT 
    count(*) as total_connections,
    count(*) FILTER (WHERE state = 'active') as active,
    count(*) FILTER (WHERE state = 'idle') as idle,
    count(*) FILTER (WHERE state = 'idle in transaction') as idle_in_xact,
    max(now() - state_change) as max_idle_time
FROM pg_stat_activity 
WHERE pid <> pg_backend_pid()

--Возможно стоит посмотреть конкретные висящие запросы
select * from pg_stat_activity where 
(now() - state_change)>'1day' 
AND state='active'



/*** В КРИТИЧНОЙ СИТУАЦИИ ИНОГДА НУЖНО СТОПНУТЬ СЕССИИ  ***/
-- Вариант с отменой запросв всех сессий
SELECT pg_cancel_backend(pid) 
FROM pg_stat_activity 
WHERE pid <> pg_backend_pid();

-- Вариант с завершением сессий по пользователю
SELECT pg_terminate_backend(pid) 
FROM pg_stat_activity 
WHERE usename = 'SHEMA_MED_NAME';

/* 
 * ВОССТАНОВЛЕНИЕ
 * (бывают ситуации, когда кто-то что-то удалил. и особенно если этот кто-то ТЫ, тебе следует развернуть систему аудита из папки db_audit)
 * данный пример работает только с той схемой
 */
select (prev_data ->> 'content')::bytea, prev_data ->> 'filename', dc.* from pol5_logs.data_changes dc where
uid = '3eb5aa71-a3cb-4674-986c-0ebe1a0c1fec'

-- поиск по report_content (на проде делал так. 2.5Gb уже медленее индексируется)
select *  from pol5_logs.data_changes dc  where  (dc.prev_data -> 'report_list_id')::integer = 472
-- но если ты добавил GIN index используй  его (должно быть быстрее, не проверял 0_0 ):
SELECT * FROM pol5_logs.data_changes WHERE prev_data @> '{"report_list_id": 472}';

-- поиск по report_list
select *  from pol5_logs.data_changes dc  where  (dc.pk::jsonb ->> 'keyid')::integer = 1214



/*
 * ДЕБАГ
 */
-- ПОИСК ПО БАЗЕ ПО ФУНКЦИЯМ
/* это одна из важных команд при отладке функций на структуру 100+ схем и т.д.
 * особено когда есть процедуры/функции матрешки,и особено когда пытаешься понять почему падает база при обращении к функция. которая использует питон
 */
SELECT  nspname, proname, prosrc, (select lanname from pg_language where  prolang=oid)
FROM    pg_catalog.pg_namespace  
JOIN    pg_catalog.pg_proc  
ON      pronamespace = pg_namespace.oid
	AND prosrc ilike '%$1%' /* поиска по коду функции */
	AND proname ilike '%$2%' /* поиск по имени функции */ 
	AND prolang = (SELECT oid FROM pg_language WHERE lanname = 'plpython3u')  /* функция использует python */
ORDER BY Proname

/* бывают ситуации, когда на сервере установлено мало дисковой памяти, 
 * и приходится бороться за каждый байт
 * В такой ситуации тебе помогут эти два запроса */
-- САМЫЕ БОЛЬШИЕ ТАБЛИЦЫ ПО БАЗЕ
with 
list_pg as (
SELECT 
st.schemaname, st.relname as "table" 
,pgd.description
,idx_blks_hit ibh
,heap_blks_read hbr
,pg_size_pretty(pg_total_relation_size(relid)) as "size", pg_total_relation_size(relid) as size_num
FROM pg_catalog.pg_statio_user_tables as st
left join pg_catalog.pg_description pgd on (
    pgd.objoid = st.relid and pgd.objsubid =0
)
where pg_total_relation_size(relid)>=power(10, 10)/2 /* всё что более 5GB */
)
select p.schemaname, p.table,  p.size 
,pg_size_pretty(pg_database_size('med')) as sum_size
, round( (p.size_num::decimal / pg_database_size('med')::decimal)*100,2) || '%' as  pers
, p.description
,p.ibh as index_cash /*Кол-во индексов в кэше*/
,p.hbr as read_bloks /*Кол-во прочитанных блоков*/
from list_pg p
ORDER BY round(p.size_num * 100 / pg_database_size('med'), 2 )  desc


/* ПРОСМОТР ТАБЛИЦЫ DOCUMENTS КУДА СОХРАНЯЮТ СКАНЫ*/
select regexp_matches(lower(filename),'\.(\w+)$')::text fexten
,count(d.id) as c
,pg_size_pretty(sum(length(d.content))::bigint) fsize
from $shema.$tablename  as d where d.filename is not null
group by fexten
union
SELECT 'ОБЩАЯ СУММА {ТАБЛИЦЫ}:' as fexten, pg_total_relation_size(relid) as c, pg_size_pretty(pg_total_relation_size(relid)) as "fsize"
FROM pg_catalog.pg_statio_user_tables where relname = '$tablename' and schemaname = '$shema'


-- ОСТАНОВКА VACUUM
/**
 *  иногда возникают ситуации, когда средства починки ломают БД (если такое происходит изучи все активные запросы)
 **/
SHOW autovacuum; -- проверь работу автовакуум
ALTER TABLE pg_catalog.pg_largeobject SET (autovacuum_enabled = false); -- отключить автовакум на конкретные таблицы
ALTER SYSTEM SET autovacuum = off; -- полное выключение

--либо понизь агресивность запуска
ALTER SYSTEM SET autovacuum_vacuum_scale_factor = 0.05;
ALTER SYSTEM SET autovacuum_analyze_scale_factor = 0.01;
ALTER SYSTEM SET autovacuum_vacuum_cost_delay = 0;
SELECT pg_reload_conf(); -- не забудь перечитать конфиг (а лучше restart базы сделать если тебе позволяют) после любых изменений


-- ИСПОЛЬЗУЙ ТОЛЬКО ЭТИ ЗАПРОСЫ!!!
ANALYZE VERBOSE; -- вообще хоть зазапускайся
VACUUM VERBOSE; -- не блокирует транзакции DML операции.. на своей базе FULL добавит только FOOL


/* ОСТОРРОЖНО ОПАСНЫЕ КОМАНДЫ, НО НЕ НАСТОЛЬКО КАК VACUUM FULL на базе 1ТБ ;)   */

-- запретить все коннекты для пользователя hated_user на базе your_database
REVOKE CONNECT ON DATABASE your_database FROM hated_user;

-- Это запрос эгоистов, базой никто больше не будет пользоваться кроме тебя! ну и возможно тебя уволят)
UPDATE pg_database SET datallowconn = false WHERE datname = 'your_database';