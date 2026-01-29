# POSTGRES BLUEPRINT
> ***"Это личная шпаргалка с субъективными оценками, а не официальная документация"***


## 🕵 ИНТРУКЦИЯ ПО shema_audit.sql



> ### <b style="color:red;"> ☠️ ВАЖНОЕ ПРЕДУПРЕЖДЕНИЕ</b>
> <b style="color:#d1001f;"> ЭТО ИНСТРУМЕНТЫ ДЛЯ ОПЫТНЫХ АДМИНИСТРАТОРОВ!</b>
>  <hr>
>
> 1. **Всегда тестируйте на DEV-окружении**
> 2. **Не запускайте на продакшене без понимания последствий**
> 3. **Некоторые команды могут остановить базу или удалить данные**
> 4. **Делайте бэкапы перед экспериментами**
>
> <i style="color:#ffcdbd;">Автор не несет ответственности за последствия использования этих скриптов.</i>


*"Код писался в условиях высоких нагрузок и срочных задач, поэтому в нём могут встречаться неидеальные решения, но он стабильно работает и закрывает ключевые задачи аудита"*

<hr> 

В последующих правках планирую исправить:
  - чрезмерная агрессивность аудита опасных запросов
  - добавлена будет параметризация для этойже функции (конкретно на автокил запросов)
  - возможно будет упрощена схема
  - для ddl аудита я очень давно планировал добавить категоризацию (ФУНКЦИЯ,ПРОЦЕДУРА, ТАБЛИЦА, ВЬЮХА) - это не сложно, даже триггер на автоопределение при добавлении можно добавить., но пока не доходят руки

Исправил:
  - исправил **GRANT ALL ON FUNCTION \*\*\*\* TO  public** отсавил тех кто их использует... по сути можно вообще выкинуть любые GRANT ALL из скрипта 

ТРЕБОВАНИЯ:
  - pg_cron (автоматизируй автоматизацию)
  - uuid-ossp (для генерации UUID вместо последовательностей)
  - plpython3u (в схеме етого нет, но поверь он нужен, в адекватных проектах при правильном использовании нужен)

## 🛠️ ШАБЛОНЫ ЗАПРОСОВ (МОНИТОРИНГ, ЭКСПРЕСС ИЗМЕНЕНИЕ КОНФИГОВ и т.д.)

Данный файл хранит заготовки запросов для быстрого поиска **(хотя не всегда быстрого)** здесь можно бытро посмотреть логи, параметры бызы, изменить параметры, есть пример со связкой из аудита


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
"весгда используй сортировку с датами это большая часть в производительности всех запросов"

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


### ЛОКАЛЬНОЕ ИЗМЕНЕНИЕ СИСТЕМНЫХ КОНФИГОВ

```sql
BEGIN;
  SET LOCAL work_mem = '64MB';  -- Только в этой транзакции!
  SELECT * from -- УЖАСТНАЯ НЕОПТИМИЗИРОВАННАЯ ФУНКЦИЯ;
COMMIT;
```

**или более радикально** (будет работать пока твое приложение держит сессию открытой)
на примере с Dbeaver. Ты открыл отдельную вкладку задал значение для сессии
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
*самый банальный, но не самый распрастраненный случай (скорее очень частный, ностолкнуться можно), если плохо организована или нагружена сеть, перебитые провода, радиационый/электромагнитный/прочий фон (флюра, кт...) особенно без экранированных проводов и т.д.*
```bash
# На сервере (программа работает в режиме Server listening)
iperf3 -s

# На любом клиенте (где происходят вылеты базы)
iperf3 -c $SERVER_IP -t 10
```
2) Мониторинг железа, ресурсов **общий**  (htop, bpytop,  *konsole+zsh* - для удобства и привычней, mc)
*Относительно частый случай - это нехватка ресурсов:*
  - *(A) Прожерливые транзакции, и ты можешь даже не понять через эти инструменты [ПОСТОЯННО]*
  - *(Б) Неудачная настройка конфига [РЕЖЕ] (конфиг настраивается только по модификации железа и первичной установки)*
  - *(C) Деградация компонентов оборудования [ПОЧТИ_МИСТИКА] но по опыту коллег бывает и последствия фатальны! обычно это полный отказ особенно если сервер не класстеризован*
  - *(D) Конфликт с другими приложениями! [НУ_СКОРЕЕ_ЧАЩЕ_ЧЕМ_РЕЖЕ] есть ряд экспертов, которые не любит или не умеет Docker, это нормально, но в условиях ограниченности ресурсов постоянных дедлайнов возникают проблемы. нужно срочно поднять сервис, давайте поднимим его рядом с базой* 

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

du -sh *          # Вывести и расчитать занятость папок
du -ch *.txt      # оценить по расширению сколько занято место в общем
```

5) Анализ запросов [https://habr.com/ru/companies/jetinfosystems/articles/245507/](ASH Viewer), Dbeaver, Pgadmin
*Максимально постоянная ситуация! В пятницу вечером приходят обновления, меняются половина функций. Выходишь в понедельник, ничего не работает, КЛАССИКА!*
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