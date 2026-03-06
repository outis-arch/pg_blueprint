# POSTGRES BLUEPRINT
> ***"Это личная шпаргалка с субъективными оценками, а не официальная документация"***


## 🕵 Системная Аудита Postgresql
ИНСТРУКЦИЯ ПО **schema_audit.sql**




> ### <b style="color:red;"> ☠️ ВАЖНОЕ ПРЕДУПРЕЖДЕНИЕ</b>
> <b style="color:#d1001f;"> ЭТО ИНСТРУМЕНТЫ ДЛЯ ОПЫТНЫХ АДМИНИСТРАТОРОВ!</b>
>  <hr>
>
> 1. **Всегда тестируй на DEV-окружении**
> 2. **Не запускай на продакшене без понимания последствий**
> 3. **Некоторые команды могут остановить базу, удалить данные, сломать структуру таблиц**
> 4. **Делай бэкапы перед экспериментами**
> 5. **Не доверяй экспертизе первого встречного, думай сам**
>
> <i style="color:#ffcdbd;">Автор не несет ответственности за последствия использования этих скриптов.</i>


*"Код писался в условиях высоких нагрузок и срочных задач, поэтому в нём могут встречаться неидеальные решения, но он стабильно работает и закрывает ключевые задачи аудита"*

<hr> 

В последующих правках планирую исправить:
  - чрезмерная агрессивность аудита опасных запросов
  - добавлена будет параметризация для этой же функции (конкретно на autokill запросов)
  - возможно будет упрощена схема
  - для ddl аудита я очень давно планировал добавить категоризацию (ФУНКЦИЯ,ПРОЦЕДУРА, ТАБЛИЦА, ВЬЮХА) - это не сложно, даже триггер на автоопределение при добавлении можно добавить., но пока не доходят руки

Исправил:
  - исправил **GRANT ALL ON FUNCTION \*\*\*\* TO  public** 

ТРЕБОВАНИЯ:
  - pg_cron (автоматизируй автоматизацию)
  - uuid-ossp (для генерации UUID вместо последовательностей)
  - plpython3u (в схеме этого нет, но поверь он нужен, в адекватных проектах при правильном использовании нужен)

## 🛠️ ШАБЛОНЫ ЗАПРОСОВ (МОНИТОРИНГ, ЭКСПРЕСС ИЗМЕНЕНИЕ КОНФИГОВ и т.д.)

Данный файл хранит заготовки запросов для быстрого поиска **(хотя не всегда быстрого)** здесь можно быстро посмотреть логи, параметры базы, изменить параметры, есть пример со связкой из аудита


## 👁️ ШПАРГАЛКА ПО ОПТИМИЗАЦИИ POSTGRESQL

### АНАЛИТИКА

##### EXPLAIN
**это легковесный вариант анализа запроса (без последствий)**
Результат: Предполагаемые стоимости, порядок сканирования (Seq Scan, Index Scan и т.д.) [НЕ ТОЧНО - НО БЫСТРО, ДО МГНОВЕНИЯ]

##### EXPLAIN ANALYZE
**Данный план по времени выполняется как и запрос (план + выполнение)**

Результат: Добавляет реальное время выполнения, количество строк, количество циклов.
##### EXPLAIN (ANALYZE, TIMING OFF)
**Выполняет запрос, но не замеряет точное время на каждом узле (быстрее).**

##### EXPLAIN (ANALYZE, BUFFERS)
**Данный план идеальный для анализа I/O**
Показывает:
 - Shared Hit – данные из кэша
 - Shared Read – чтение с диска
 - temp read/write – временные файлы

##### EXPLAIN (ANALYZE, VERBOSE)
**детальная информация (для сложных запросов с джойнами)**
- Имена столбцов в выводе
- Алиасы таблиц
- Фильтры для каждого узла



### ИНДЕКСЫ
Если таблица используется для чтения сильно чаще, чем для записи
то ты можешь отключить fastupdate (включен по умолчанию)

[+] Мгновенный поиск по новым данным        [-] Медленнее INSERT (на 10-30%)
[+] Стабильная производительность           [-] Больше write amplification
[+] Предсказуемое поведение                 [-] Может тормозить массовую вставку

```sql
CREATE INDEX idx_chat_messages_gin
ON chat_messages USING GIN (metadata)
WITH (fastupdate = off);  -- лучше отключать на данные которые редко обновляются
```

> ПРИМЕРЫ, используем абстрактные таблицы из (lab_orders, patvisit)


#### Составной индекс с сортировкой по дате
"используй сортировку с датами это большая часть в производительности всех запросов"

```sql
CREATE INDEX idx_orders_status_date
ON lab_orders (status, created_at DESC);
```


#### Индекс с date_trunc (агрегация по дням/месяцам)

```sql
CREATE INDEX idx_sales_monthly
ON patvisit ((date_trunc('day', date_in)));
```

#### Частичный индекс по периоду

```sql
CREATE INDEX idx_recent_activities
ON patvisit (pat_id, date_in DESC)
WHERE date_in > CURRENT_DATE - INTERVAL '90 days';
```

#### Индекс временных интервалов
```sql
CREATE INDEX idx_periods_dates
ON patvisit (id, date_in, date_out);
```

### ХИТРОСТЬ ПО ИЗМЕНЕНИЮ СЛОЖНЫХ ФУНКЦИЙ/ПРОЦЕДУР

*Самая распространенная задача встречается, когда в огромную поломанную функцию тебя просят добавить одно поле. Для тех, кто не видел АД - это тривиальная задача. Но тот, кто видел труды извращенцев (дублирующийся запрос 13-50 раз подряд через UNION ALL или данные через REFCURSOR, где тебе нужно просто сделать маленький JOIN к другой таблице)* - **тот знает, что черт его знает, с какой стороны к этому БДСМ-коду подойти, чтобы не стать его частью.**

> **Совет.** Не занимайся фигней! Делай функцию-обертку и болт клади на то, чтобы разбираться в этом зоопарке. Если те, кому платят больше, тоже его кладут на нормальную архитектуру - почему ты должен страдать?

Что тебе даст обертка:
 - **Безопасность** - накосячил? просто верни оригинальную функцию (ты её не трогал!)
 - **Гибкость/расширяемость** - именно функция, а не процедура даёт гибкость. Любые данные, любые манипуляции с данными
 - **Здоровые нервы** - ни один порядочный специалист-коллега не пожелает такого зла другому. Добавлять одно маленькое поле 18 раз в одинаковый код


```sql
CREATE OR REPLACE FUNCTION pol5_sh.get_flg_data(p_year character varying DEFAULT '2025'::character varying, p_struct_id character varying DEFAULT NULL::character varying, p_dep_code character varying DEFAULT NULL::character varying, p_level bigint DEFAULT NULL::bigint, p_mode bigint DEFAULT 1, p_malomob bigint DEFAULT 0)
 RETURNS TABLE(fio character varying, birth character varying, num character varying, pin_oms character varying, last_dat character varying, plan_dates character varying, is_malomob character varying)
 LANGUAGE plpgsql
AS $function$
DECLARE
    _cur refcursor;
    _fio VARCHAR;
    _birth VARCHAR;
    _num VARCHAR;
    _pin_oms VARCHAR;
    _last_dat VARCHAR;
    _plan_dates VARCHAR;
    _is_malomob VARCHAR;
BEGIN
    -- Создаем временную таблицу со структурой сложной функции (в которой будущему SENIORу зазорно ковыряться)
    CREATE TEMP TABLE temp_flg_result (
        fio VARCHAR,
        birth VARCHAR,
        num VARCHAR,
        pin_oms VARCHAR,
        last_dat VARCHAR,
        plan_dates VARCHAR,
        is_malomob VARCHAR
    ) ON COMMIT DROP;

    /*
      если процедура реальное исчадие АДА 
      то добавь индекс (но смысл есть только на огромных данных! которые тебе не обработать)

      CREATE INDEX ON temp_flg_result (num);  -- допустим мне по номеру карты 
                                              -- нужно было определить пациента 
                                              -- и добавить участок

      P.S.  Только не добавляй индексы (ОСОБЕННО НА ВРЕМЕННУЮ ТАБЛИЦУ) после заполнения данными... 😈
    */
    
    -- Вызываем их процедуру
    CALL pkg_ru42_flg.plan_flg(p_year, p_struct_id, p_dep_code, p_level, p_mode, p_malomob, _cur);
    
    -- Читаем данные из курсора и вставляем во временную таблицу
    LOOP
        FETCH _cur INTO _fio, _birth, _num, _pin_oms, _last_dat, _plan_dates, _is_malomob;
        EXIT WHEN NOT FOUND;
        
        INSERT INTO temp_flg_result VALUES (_fio, _birth, _num, _pin_oms, _last_dat, _plan_dates, _is_malomob);
    END LOOP;
    
    -- Закрываем курсор
    CLOSE _cur;
    
    -- Возвращаем данные из временной таблицы... можно прямо здесь модифицироваться запрос... 
    RETURN QUERY SELECT * FROM temp_flg_result;
    
    -- Временная таблица удалится автоматически (ON COMMIT DROP)
END;
$function$
;
```

### ЛОКАЛЬНОЕ ИЗМЕНЕНИЕ СИСТЕМНЫХ КОНФИГОВ

```sql
BEGIN;
  SET LOCAL work_mem = '64MB';  -- Только в этой транзакции!
  SELECT * from -- УЖАСТНАЯ НЕОПТИМИЗИРОВАННАЯ ФУНКЦИЯ;
COMMIT;
```

**или более радикально** (будет работать пока твое приложение держит сессию открытой)
на примере с Dbeaver. Ты открыл отдельную вкладку, задал значение для сессии
и для этой вкладки ты будешь работать с этими параметрами

```sql
SET SESSION work_mem = '128MB';  -- На всё время соединения
SELECT запрос1;
SELECT запрос2;
```


### ВРЕМЕННЫЕ ТАБЛИЦЫ (TEMP TABLES)

**Когда использовать:**
- Разбиение сложного запроса на части
- Кэширование промежуточных результатов
- Упрощение сложных JOIN
- Работа с одним набором данных в нескольких запросах

> [!] Пример использования

```sql
-- 1. Создаем временную таблицу
CREATE TEMP TABLE temp_user_orders AS
SELECT
    u.id AS user_id,
    u.email,
    u.created_at AS user_created,
    COUNT(o.id) AS total_orders,
    SUM(o.amount) AS total_amount,
    MAX(o.created_at) AS last_order_date
FROM users u
LEFT JOIN orders o ON u.id = o.user_id
WHERE u.created_at > '2026-01-01'
  AND u.is_active = true
GROUP BY u.id, u.email, u.created_at;

-- 2. Создаем индекс для быстрого поиска по временной таблице
CREATE INDEX idx_temp_user_orders_amount ON temp_user_orders (total_amount DESC);
CREATE INDEX idx_temp_user_orders_date ON temp_user_orders (last_order_date DESC);
```

**по завершению сессии данная таблица удалится данные отчистятся** Очень удобно, если исправляешь функцию с множественным дублированием одного условия
там где разработчик их связывает десятками union all

## ИНСТРУМЕНТЫ АДМИНИСТРИРОВАНИЯ

1) Анализ сети (iperf3, ping)
*самый банальный, но не самый распространенный случай (скорее очень частный, но столкнуться можно), если плохо организована или нагружена сеть, перебитые провода, радиационный/электромагнитный/прочий фон (флюра, кт...) особенно без экранированных проводов и т.д.*
```bash
# На сервере (программа работает в режиме Server listening)
iperf3 -s

# На любом клиенте (где происходят вылеты базы)
iperf3 -c $SERVER_IP -t 10
```
2) Мониторинг железа, ресурсов **общий**  (htop, bpytop,  *konsole+zsh* - для удобства и привычней, mc)
*Относительно частый случай - это нехватка ресурсов:*
  - *(A) Прожорливые транзакции, и ты можешь даже не понять через эти инструменты [ПОСТОЯННО]*
  - *(Б) Неудачная настройка конфига [РЕЖЕ] (конфиг настраивается только по модификации железа и первичной установки)*
  - *(C) Деградация компонентов оборудования [ПОЧТИ_МИСТИКА], но по опыту коллег бывает и последствия фатальны! Обычно это полный отказ особенно если сервер не кластеризован*
  - *(D) Конфликт с другими приложениями! [НУ_СКОРЕЕ_ЧАЩЕ_ЧЕМ_РЕЖЕ] есть ряд экспертов, которые не любит или не умеет Docker, это нормально, но в условиях ограниченности ресурсов постоянных дедлайнов возникают проблемы. "Нужно срочно поднять ещё один сервис, давайте поднимем его рядом с базой, потом перенесём"* 

```bash
# Мониторинг активных сессий в реальном времени
watch -n 2 "psql -c \"SELECT pid, usename, query, state, now() - query_start as duration FROM pg_stat_activity WHERE state != 'idle' ORDER BY duration DESC;\""

# Мониторинг блокировок
watch -n 2 "psql -c \"SELECT blocked_locks.pid AS blocked_pid, blocking_locks.pid AS blocking_pid FROM pg_locks blocked_locks JOIN pg_locks blocking_locks ON blocking_locks.locktype = blocked_locks.locktype AND blocking_locks.DATABASE IS NOT DISTINCT FROM blocked_locks.DATABASE AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid AND blocking_locks.pid != blocked_locks.pid WHERE NOT blocked_locks.granted;\""

htop -u postgres 
bpytop --preset minimal  
# Проверка памяти:
free -h                   # общая память
cat /proc/meminfo | grep -E "(MemFree|Cached|SwapCached)"

# Проверка CPU:
mpstat -P ALL 1 5         # загрузка всех ядер
```

4) Анализ дисков (ncdu/du-dust, iostat, iotop)
*Блин, ну это тоже **классика** перестает работать авторизация на сайте, потому что система не может сохранить сессию на своем временном хранилище; система адово лагает и тормозит при подключении ssh*
```bash
df -hT --total    # более менее полная информация по дискам добавь параметр -a чтобы точно всё вывести
lsblk -fmt        # тоже выводятся разделы

du -sh *          # Вывести и рассчитать занятость папок
du -ch *.txt      # оценить по расширению сколько занято место в общем
```

5) Анализ запросов [https://habr.com/ru/companies/jetinfosystems/articles/245507/](ASH Viewer), Dbeaver, Pgadmin
*Максимально постоянная ситуация! В пятницу вечером приходят обновления, меняются половина функций. Утро, понедельник, ничего не работает, ВЕЧНАЯ КЛАССИКА!*
Рекомендую посмотреть ASH Viewer (сам не знал про этот инструмент в момент написания данного README)

```bash
# ASH Viewer — коммерческий инструмент от Postgres Pro.
# Бесплатные альтернативы:
# 1. pg_activity (консольный мониторинг):
pip install pg_activity
pg_activity -U postgres -h localhost

# 2. pgCenter:
docker run -it --rm -e PGUSER=postgres lesovsky/pgcenter
```

### 📚 ОФИЦИАЛЬНЫЕ РЕСУРСЫ
- [Документация PostgreSQL](https://www.postgresql.org/docs/)
- [pg_stat_statements](https://www.postgresql.org/docs/current/pgstatstatements.html)
- [EXPLAIN](https://www.postgresql.org/docs/current/using-explain.html)