/***********************************************/
--------------  СОЗДАЕМ СХЕМЫ
/***********************************************/
CREATE SCHEMA pol5_logs AUTHORIZATION postgres;


/***********************************************/
--------------  СОЗДАЕМ ТАБЛИЦЫ
/***********************************************/

/***               ATTATION_TABLE              ***/
CREATE TABLE pol5_logs.attation_requests (
	uid uuid DEFAULT uuid_generate_v4() NOT NULL,
	pid int4 NOT NULL,
	query_hash text NOT NULL,
	username text NULL,
	datname text NULL,
	client_addr inet NULL,
	client_hostname text NULL,
	application_name text NULL,
	backend_type text NULL,
	query_text text NULL,
	query_start timestamptz NULL,
	state text NULL,
	wait_event_type text NULL,
	wait_event text NULL,
	locks_waiting bool DEFAULT false NULL,
	blocks_others_count int4 DEFAULT 0 NULL,
	first_seen timestamptz DEFAULT now() NULL,
	last_seen timestamptz DEFAULT now() NULL,
	total_duration interval DEFAULT '00:00:00'::interval NULL,
	times_seen int4 DEFAULT 1 NULL,
	danger_mark int4 DEFAULT 0 NULL,
	danger_reason text NULL,
	status text NULL,
	killed bool DEFAULT false NULL,
	kill_time timestamptz NULL,
	kill_by text NULL,
	created_at timestamptz DEFAULT now() NULL,
	updated_at timestamptz DEFAULT now() NULL,
	CONSTRAINT attation_requests_pkey PRIMARY KEY (uid),
	CONSTRAINT attation_requests_status_check CHECK ((status = ANY (ARRAY['new'::text, 'active'::text, 'warning'::text, 'critical'::text, 'finished'::text, 'killed'::text, 'error'::text])))
);
CREATE INDEX idx_attation_requests_danger ON pol5_logs.attation_requests USING btree (danger_mark DESC);
CREATE INDEX idx_attation_requests_hash ON pol5_logs.attation_requests USING btree (query_hash);
CREATE INDEX idx_attation_requests_last_seen ON pol5_logs.attation_requests USING btree (last_seen DESC);
CREATE INDEX idx_attation_requests_pid ON pol5_logs.attation_requests USING btree (pid);
CREATE INDEX idx_attation_requests_status ON pol5_logs.attation_requests USING btree (status);
CREATE UNIQUE INDEX unique_active_process ON pol5_logs.attation_requests USING btree (pid) WHERE (status = ANY (ARRAY['new'::text, 'active'::text, 'warning'::text, 'critical'::text]));


-- Permissions
ALTER TABLE pol5_logs.attation_requests OWNER TO postgres;
GRANT ALL ON TABLE pol5_logs.attation_requests TO postgres;


/***            DB_SIZE             ***/
CREATE TABLE pol5_logs.db_size (
	uid uuid DEFAULT uuid_generate_v4() NOT NULL,
	sz text DEFAULT pg_size_pretty(pg_database_size(current_database()::name)) NOT NULL,
	db text DEFAULT current_database()::text NOT NULL,
	dt_req timestamp DEFAULT CURRENT_TIMESTAMP NULL,
	tb_stat jsonb NULL
);

-- Permissions

ALTER TABLE pol5_logs.db_size OWNER TO postgres;
GRANT ALL ON TABLE pol5_logs.db_size TO postgres;



/***        DDL LOG         ***/
CREATE TABLE pol5_logs.ddl_log (
	uid uuid DEFAULT uuid_generate_v4() NOT NULL,
	username text NULL,
	object_tag text NULL,
	ddl_command text NULL,
	dt_event timestamp DEFAULT CURRENT_TIMESTAMP NULL,
	changes int8 NULL,
	CONSTRAINT ddl_log_pkey PRIMARY KEY (uid)
);



-- Permissions

ALTER TABLE pol5_logs.ddl_log OWNER TO postgres;
GRANT DELETE, TRIGGER, TRUNCATE, SELECT, REFERENCES, INSERT, UPDATE ON TABLE pol5_logs.ddl_log TO postgres;
GRANT SELECT, INSERT, UPDATE ON TABLE pol5_logs.ddl_log TO dli;



/***         DATA CHANGES           ***/
CREATE TABLE pol5_logs.data_changes (
	uid uuid DEFAULT uuid_generate_v4() NOT NULL,
	pk varchar(50) NULL,
	shema varchar(300) NULL,
	"table" varchar(300) NULL,
	prev_data jsonb NULL,
	pg_user varchar DEFAULT CURRENT_USER NULL,
	dt_event timestamp DEFAULT CURRENT_TIMESTAMP NULL,
	"event" varchar(300) NULL,
	changes int8 NULL,
	CONSTRAINT filter_changes_pk PRIMARY KEY (uid)
);
CREATE INDEX data_changes_dt_event_idx ON pol5_logs.data_changes USING btree (dt_event DESC);
CREATE INDEX data_changesidx_table_idx ON pol5_logs.data_changes USING btree (shema, "table");
CREATE INDEX idx_data_changes_prev_data_gin 
ON pol5_logs.data_changes 
USING GIN (prev_data);


-- Permissions

ALTER TABLE pol5_logs.data_changes OWNER TO postgres;
GRANT DELETE, TRIGGER, TRUNCATE, SELECT, REFERENCES, INSERT, UPDATE ON TABLE pol5_logs.data_changes TO postgres;
GRANT SELECT, INSERT, UPDATE ON TABLE pol5_logs.data_changes TO dli;




/***         TEST TABLE             ***/
CREATE TABLE pol5_logs.test_tb (
	uid uuid DEFAULT uuid_generate_v4() NOT NULL,
	dt_event timestamp DEFAULT CURRENT_TIMESTAMP NULL,
	"data" text NULL,
	"desc" text NULL,
	CONSTRAINT test_tb_pkey PRIMARY KEY (uid)
);

-- Permissions

ALTER TABLE pol5_logs.test_tb OWNER TO postgres;
GRANT DELETE, TRIGGER, TRUNCATE, SELECT, REFERENCES, INSERT, UPDATE ON TABLE pol5_logs.test_tb TO postgres;
GRANT SELECT, INSERT, UPDATE ON TABLE pol5_logs.test_tb TO dli;





/***********************************************/
--------------  СОЗДАЕМ ФУНКЦИИ И ПРОЦЕДУРЫ
/***********************************************/
/***         ФУНКЦИЯ НА ЗАЩИТУ ДАННЫХ ТАБЛИЦЫ       ***/
CREATE OR REPLACE FUNCTION pol5_logs.row_to_log()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$ 
DECLARE
	reg_id JSONB;
	affected_row JSON;

BEGIN 
    IF TG_OP IN('INSERT', 'UPDATE') THEN
        affected_row := row_to_json(NEW);
    ELSE
        affected_row := row_to_json(OLD);
    END IF;


 WITH pk_columns (attname) AS (
        SELECT
            CAST(a.attname AS TEXT)
        FROM
            pg_index i
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
        WHERE
            i.indrelid = TG_RELID
            AND i.indisprimary
    )
    SELECT
        json_object_agg(key, value) INTO reg_id
    FROM
        json_each_text(affected_row)
    WHERE
        key IN(SELECT attname FROM pk_columns);

INSERT INTO pol5_logs.data_changes (
pk,
shema, "table",
prev_data, 
pg_user, "event"
) 
VALUES (
reg_id, 
TG_TABLE_SCHEMA, TG_TABLE_NAME, 
to_jsonb(OLD),
current_user, TG_OP
 ); 

RETURN NEW;
END; $function$
;

-- Permissions

ALTER FUNCTION pol5_logs.row_to_log() OWNER TO postgres;
GRANT ALL ON FUNCTION pol5_logs.row_to_log() TO postgres;


/***        ЗАЩИТА ОТ ИЗМЕНЕНИЯ DDL_LOG     ***/
CREATE OR REPLACE FUNCTION pol5_logs.log_ddl_changes()
 RETURNS event_trigger
 LANGUAGE plpgsql
AS $function$ 

declare ts TEXT := current_query();

BEGIN 

if ts ~* '\y(?:ALTER |DROP |CREATE |REPLACE |TRUNCATE |COMMENT )\y' then
INSERT INTO pol5_logs.ddl_log (username, object_tag, ddl_command) 
VALUES (current_user, tg_tag, current_query() ); 
end if;

END; $function$
;

-- Permissions

ALTER FUNCTION pol5_logs.log_ddl_changes() OWNER TO postgres;
GRANT ALL ON FUNCTION pol5_logs.log_ddl_changes() TO postgres;
GRANT ALL ON FUNCTION pol5_logs.log_ddl_changes() TO dli;



/************* ФУНКИЦИИ НА МОНИТОРИНГ */


/***        ЗАПИСЬ В ЛОГ        ***/
CREATE OR REPLACE FUNCTION pol5_logs.catch_problem_queries()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_current_time timestamptz := now();
    v_process record;
    v_query_hash text;
    v_danger_info jsonb;
    v_locks_waiting boolean;
    v_blocks_others integer;
    v_existing_uid uuid;
    v_counter integer := 0;
BEGIN
/*   ФУНКЦИЯ МОНИТОРИНГА ЗАВИСШИХ И МЕРТВЫХ ЗАПРОСОВ (которые могут стать причиной падения БД) 	   */
    -- Собираем текущие долгие процессы (>1 минуты)
    FOR v_process IN 
        SELECT 
            a.pid,
            a.usename as username,
            a.datname,
            a.client_addr,
            a.client_hostname,
            a.application_name,
            a.backend_type,
            a.query,
            a.query_start,
            a.state,
            a.wait_event_type,
            a.wait_event,
            v_current_time - a.query_start as duration
        FROM pg_stat_activity a
        WHERE a.state IN ('active', 'idle in transaction')
          AND a.query IS NOT NULL
          AND a.query NOT LIKE '%pg_stat_activity%'
          AND a.query NOT LIKE '%catch_problem_queries%'
          AND a.pid <> pg_backend_pid()
          AND a.query_start IS NOT NULL
          AND v_current_time - a.query_start > interval '1 minute'
    LOOP
        -- Проверяем блокировки
        SELECT EXISTS (
            SELECT 1 
            FROM pg_locks l 
            WHERE l.pid = v_process.pid 
              AND NOT l.granted
        ) INTO v_locks_waiting;
        
        -- Сколько блокирует других
        SELECT COUNT(*) INTO v_blocks_others
        FROM pg_locks l1
        WHERE l1.pid = v_process.pid
          AND l1.granted = true
          AND EXISTS (
              SELECT 1 
              FROM pg_locks l2
              WHERE l2.pid <> v_process.pid
                AND NOT l2.granted
                AND l2.locktype = l1.locktype
                AND l2.database IS NOT DISTINCT FROM l1.database
                AND l2.relation IS NOT DISTINCT FROM l1.relation
          );
        
        -- Рассчитываем опасность
        v_danger_info := pol5_logs.calculate_danger(
            v_process.duration,
            v_process.state,
            v_process.wait_event_type,
            v_process.query,
            v_locks_waiting,
            v_blocks_others
        );
        
        -- Создаем хэш запроса
        v_query_hash := md5(
            COALESCE(v_process.username, '') || '|' ||
            COALESCE(v_process.datname, '') || '|' ||
            COALESCE(
                regexp_replace(
                    regexp_replace(v_process.query, '\$\d+', '?', 'g'),
                    '\d+', '#', 'g'
                ), 
                ''
            ) || '|' ||
            (v_danger_info->>'status')::text
        );
        
        -- Ищем существующую активную запись
        SELECT uid INTO v_existing_uid
        FROM pol5_logs.attation_requests 
        WHERE pid = v_process.pid 
          AND status IN ('new', 'active', 'warning', 'critical')
        LIMIT 1;
        
        IF v_existing_uid IS NOT NULL THEN
            -- ОБНОВЛЯЕМ
            UPDATE pol5_logs.attation_requests 
            SET 
                last_seen = v_current_time,
                total_duration = total_duration + (v_current_time - last_seen),
                times_seen = times_seen + 1,
                state = v_process.state,
                wait_event_type = v_process.wait_event_type,
                wait_event = v_process.wait_event,
                locks_waiting = v_locks_waiting,
                blocks_others_count = v_blocks_others,
                danger_mark = GREATEST(danger_mark, (v_danger_info->>'score')::integer),
                danger_reason = COALESCE(
                    CASE 
                        WHEN (v_danger_info->>'score')::integer > danger_mark 
                        THEN v_danger_info->>'reasons'
                        ELSE danger_reason
                    END,
                    v_danger_info->>'reasons'
                ),
                status = v_danger_info->>'status'
            WHERE uid = v_existing_uid;
            
            v_counter := v_counter + 1;
            
        ELSE
            -- ВСТАВЛЯЕМ НОВУЮ
            INSERT INTO pol5_logs.attation_requests (
                pid,
                query_hash,
                username,
                datname,
                client_addr,
                client_hostname,
                application_name,
                backend_type,
                query_text,
                query_start,
                state,
                wait_event_type,
                wait_event,
                locks_waiting,
                blocks_others_count,
                first_seen,
                last_seen,
                total_duration,
                danger_mark,
                danger_reason,
                status
            ) VALUES (
                v_process.pid,
                v_query_hash,
                v_process.username,
                v_process.datname,
                v_process.client_addr,
                v_process.client_hostname,
                v_process.application_name,
                v_process.backend_type,
                LEFT(v_process.query, 4000),
                v_process.query_start,
                v_process.state,
                v_process.wait_event_type,
                v_process.wait_event,
                v_locks_waiting,
                v_blocks_others,
                v_process.query_start,
                v_current_time,
                v_process.duration,
                (v_danger_info->>'score')::integer,
                v_danger_info->>'reasons',
                v_danger_info->>'status'
            );
            
            v_counter := v_counter + 1;
        END IF;
    END LOOP;
    
    -- Помечаем завершенные процессы
    UPDATE pol5_logs.attation_requests ar
    SET status = 'finished'
    WHERE ar.status IN ('new', 'active', 'warning', 'critical')
      AND ar.pid IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 
          FROM pg_stat_activity a 
          WHERE a.pid = ar.pid
            AND a.state IN ('active', 'idle in transaction')
      );
    

	/* АВТОУБИЙСТВО ЕСЛИ БАЗЕ БУДЕТ БОЛЬНО
    WITH to_kill AS (
        SELECT pid, username, datname, query_text, danger_mark
        FROM pol5_logs.attation_requests 
        WHERE status = 'critical'
          AND killed = false
          AND (danger_mark >= 20 OR EXTRACT(epoch FROM total_duration) > 1800)  -- 30 минут
          AND pid IN (SELECT pid FROM pg_stat_activity WHERE state = 'active')
        LIMIT 5  -- максимум 5 за раз
    )
    UPDATE pol5_logs.attation_requests ar
    SET 
        killed = true,
        kill_time = v_current_time,
        kill_by = current_user,
        status = 'killed'
    FROM to_kill tk
    WHERE ar.pid = tk.pid
      AND pg_terminate_backend(tk.pid);
	*/

    
    RETURN v_counter;
    
EXCEPTION 
    WHEN OTHERS THEN
        -- Логируем ошибку
        INSERT INTO pol5_logs.attation_requests (
            pid, username, datname, query_text, status, danger_reason
        ) VALUES (
            0, 'SYSTEM', current_database(), 
            'ERROR in catch_problem_queries: ' || SQLERRM,
            'error',
            'Function failed'
        );
        RAISE WARNING 'ERROR in catch_problem_queries: %', SQLERRM;
        RETURN -1;
END;
$function$
;

-- Permissions

ALTER FUNCTION pol5_logs.catch_problem_queries() OWNER TO postgres;
GRANT ALL ON FUNCTION pol5_logs.catch_problem_queries() TO postgres;


/****      ДОБАВИТЬ В АВТОЗАПУСК         ***/
SELECT cron.schedule(
    'catch_bastards_queries',
    '*/5 * * * *',               
    'SELECT pol5_logs.catch_problem_queries();'
);



/***            РАСЧЕТ ОПАСНЫХ ДЛЯ ВЫВОДА       ***/
CREATE OR REPLACE FUNCTION pol5_logs.calculate_danger(p_duration interval, p_state text, p_wait_event_type text, p_query text, p_locks_waiting boolean, p_blocks_others integer)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    danger_score integer := 0;
    reasons text[] := '{}';
    duration_seconds integer;
BEGIN
    duration_seconds := EXTRACT(epoch FROM p_duration);
    
    -- 1. Время выполнения
    IF duration_seconds > 3600 THEN 
        danger_score := danger_score + 10;
        reasons := array_append(reasons, '>1 часа');
    ELSIF duration_seconds > 1800 THEN 
        danger_score := danger_score + 7;
        reasons := array_append(reasons, '>30 минут');
    ELSIF duration_seconds > 600 THEN 
        danger_score := danger_score + 5;
        reasons := array_append(reasons, '>10 минут');
    ELSIF duration_seconds > 300 THEN 
        danger_score := danger_score + 3;
        reasons := array_append(reasons, '>5 минут');
    ELSIF duration_seconds > 60 THEN 
        danger_score := danger_score + 1;
        reasons := array_append(reasons, '>1 минуты');
    END IF;
    
    -- 2. Состояние процесса
    IF p_state = 'idle in transaction' THEN 
        danger_score := danger_score + 5;
        reasons := array_append(reasons, 'idle in transaction');
    END IF;
    
    -- 3. Ожидания
    IF p_wait_event_type = 'Lock' THEN 
        danger_score := danger_score + 5;
        reasons := array_append(reasons, 'Lock wait');
    ELSIF p_wait_event_type = 'LWLock' THEN 
        danger_score := danger_score + 4;
        reasons := array_append(reasons, 'LWLock wait');
    ELSIF p_wait_event_type = 'IO' THEN 
        danger_score := danger_score + 3;
        reasons := array_append(reasons, 'IO wait');
    END IF;
    
    -- 4. Паттерны запросов
    IF p_query ILIKE '%CROSS JOIN%' THEN 
        danger_score := danger_score + 5;
        reasons := array_append(reasons, 'CROSS JOIN');
    END IF;
    
    IF p_query ILIKE '%WITH RECURSIVE%' THEN 
        danger_score := danger_score + 4;
        reasons := array_append(reasons, 'RECURSIVE CTE');
    END IF;
    
    IF p_query ILIKE '%DISTINCT ON%' THEN 
        danger_score := danger_score + 3;
        reasons := array_append(reasons, 'DISTINCT ON');
    END IF;
    
    IF p_query ILIKE '%ORDER BY%' AND p_query ILIKE '%LIMIT%' THEN 
        danger_score := danger_score + 2;
        reasons := array_append(reasons, 'Sort for LIMIT');
    END IF;
    
    -- 5. Блокировки
    IF p_locks_waiting THEN 
        danger_score := danger_score + 3;
        reasons := array_append(reasons, 'Waiting lock');
    END IF;
    
    IF p_blocks_others > 0 THEN 
        danger_score := danger_score + (LEAST(p_blocks_others, 5) * 2);  -- до 10 баллов
        reasons := array_append(reasons, 'Blocks ' || p_blocks_others || ' processes');
    END IF;
    
    -- Определяем статус
    RETURN jsonb_build_object(
        'score', LEAST(danger_score, 30),
        'reasons', array_to_string(reasons, '; '),
        'status', CASE 
            WHEN danger_score >= 15 THEN 'critical'
            WHEN danger_score >= 10 THEN 'warning'
            WHEN danger_score >= 5 THEN 'active'
            ELSE 'new'
        END
    );
END;
$function$
;

-- Permissions

ALTER FUNCTION pol5_logs.calculate_danger(interval, text, text, text, bool, int4) OWNER TO postgres;
GRANT ALL ON FUNCTION pol5_logs.calculate_danger(interval, text, text, text, bool, int4) TO postgres;



/***        ВЫВОД ИЗ ТАБЛИЦЫ ОПАСНЫХ ФУНКЦИЙ        ***/
CREATE OR REPLACE FUNCTION pol5_logs.show_problem_queries(p_limit integer DEFAULT 20, p_status text DEFAULT NULL::text)
 RETURNS TABLE(pid integer, username text, database text, duration text, danger integer, danger_level text, status text, locks text, blocks integer, wait_info text, query_preview text, first_seen text, last_seen text)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    SELECT 
        ar.pid,
        ar.username,
        ar.datname as database,
        COALESCE(
            round(EXTRACT(epoch FROM ar.total_duration)::numeric, 0)::text || ' сек',
            '0 сек'
        ) as duration,
        ar.danger_mark as danger,
        CASE 
            WHEN ar.danger_mark >= 20 THEN '☠️ СМЕРТЬ'
            WHEN ar.danger_mark >= 15 THEN '🚔 КРИТИЧЕСКИ'
            WHEN ar.danger_mark >= 10 THEN '☢️ ОПАСНО'
            WHEN ar.danger_mark >= 5 THEN '✋ ПРЕДУПРЕЖДЕНИЕ'
            ELSE '🛡  НОРМ'
        END as danger_level,
        ar.status,
        CASE 
            WHEN ar.locks_waiting AND ar.blocks_others_count > 0 THEN '🔒⛓️'
            WHEN ar.locks_waiting THEN '🔒'
            WHEN ar.blocks_others_count > 0 THEN '⛓️'
            ELSE ''
        END as locks,
        ar.blocks_others_count as blocks,
        COALESCE(ar.wait_event_type || '/' || ar.wait_event, '') as wait_info,
        LEFT(COALESCE(ar.query_text, ''), 60) as query_preview,
        to_char(ar.first_seen, 'HH24:MI:SS') as first_seen,
        to_char(ar.last_seen, 'HH24:MI:SS') as last_seen
    FROM pol5_logs.attation_requests ar
    WHERE (p_status IS NULL OR ar.status = p_status)
      AND ar.status NOT IN ('error', 'finished')
    ORDER BY 
        CASE ar.status 
            WHEN 'critical' THEN 1
            WHEN 'warning' THEN 2
            WHEN 'active' THEN 3
            WHEN 'new' THEN 4
            ELSE 5
        END,
        ar.danger_mark DESC,
        ar.last_seen DESC
    LIMIT p_limit;
END;
$function$
;

-- Permissions

ALTER FUNCTION pol5_logs.show_problem_queries(int4, text) OWNER TO postgres;
GRANT ALL ON FUNCTION pol5_logs.show_problem_queries(int4, text) TO postgres;




/***********************************************/
--------------  СОБЫТИЙНЫЙ ТРИГЕР НА DDL лог
/***********************************************/
CREATE EVENT TRIGGER log_ddl_trigger ON ddl_command_end
	EXECUTE FUNCTION pol5_logs.log_ddl_changes()



-- Table Triggers
create trigger update_attation_requests_updated_at before
update
    on
    pol5_logs.attation_requests for each row execute function pol5_logs.update_updated_at_column();

-- Table Triggers
create trigger ddl_log_reqlog after
delete
    or
update
    on
    pol5_logs.ddl_log for each row execute function pol5_logs.row_to_log();

-- Table Triggers
create trigger test_tb_reqlog after
delete
    or
update
    on
    pol5_logs.test_tb for each row execute function pol5_logs.row_to_log();