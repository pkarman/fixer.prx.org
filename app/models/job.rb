# encoding: utf-8

class Job < BaseModel
  enum status: STATUS_VALUES

  belongs_to :application, class_name: 'Doorkeeper::Application'
  has_many :tasks, -> { order(position: :desc) }
  has_one :web_hook, as: :informer

  before_validation(on: :create) { self.status = CREATED }

  validates_presence_of :job_type, :status, :application_id
  validates_inclusion_of :job_type, in: JOB_TYPES

  scope :incomplete, -> { where(status: [Job.statuses[CREATED], Job.statuses[ERROR]]) }
  scope :failed, -> { where(status: Job.statuses[ERROR]) }

  def ended?
    tasks(true).all?{ |t| t.ended? }
  end

  def success?
    tasks(true).all?{ |t| t.success? }
  end

  def retry?
    retry_count < retry_max
  end

  def task_ended(task)
    return if cancelled?
    logger.debug "task_ended for job #{id}: task: #{task.id}"
    with_lock do
      if ended?
        logger.debug "job: task_ended: all ended"
        success? ? complete! : error!
        send_call_back
        retry_on_error
      else
        logger.debug "job: task_ended: NOT all ended: " + tasks.collect{ |t| "#{t.id}:#{t.status}" }.join(', ')
      end
    end
  end

  def send_call_back(force=false)
    self.web_hook = nil if force
    return if (call_back.blank? || web_hook)
    create_web_hook(url: call_back, message: to_call_back_message)
  end

  def retry_on_error
    return if (success? || cancelled? || !retry? || retry_scheduled?)
    # this is the current job
    # schedule_in(retry_delay.seconds, {:method=>:scheduled_retry})

    # try this for exponential retry
    # delay = (2**(retry_count)/2) * retry_delay.seconds
    schedule_in(calculate_retry_delay.seconds, { method: :scheduled_retry } )
  end

  def calculate_retry_delay
    c = retry_count.to_i
    d = retry_delay || 600
    [(2**(c + 1)/2) * d.seconds, 7.days].min
  end

  def scheduled_retry(data={})
    self.retry(false)
  end

  def retry(force=false)
    return if (!force && (success? || cancelled? || !retry?))

    # remove old webhook so new one can be created
    self.web_hook = nil

    self.update_attributes(status:      RETRYING,
                           retry_count: (retry_count + 1),
                           retry_max:   [(retry_count + 1), retry_max].max)

    tasks.each{ |t| t.retry_task(force) }
  end

  def to_call_back_message
    to_json(
      only: [:id, :job_type, :original, :status],
      include: {
        tasks: {
          only: [:id, :task_type, :result, :label, :options, :call_back],
          methods: :result_details
        }
      }
    )
  end

  def self.create_from_message(h, application=nil)
    tasks = h.delete('tasks') || []
    job = Job.new(h)
    job.application = application

    begin
      Job.transaction do
        job.save!
        tasks.each do |t|
          # Handle when task attributes are classname prefixed or not
          if asequence = extract_sequence(t)
            sequence_tasks = asequence.delete('tasks') || []
            sequence = Sequence.new(asequence)
            job.tasks << sequence
            sequence.save!
            sequence_tasks.each { |st| sequence.tasks.create!(extract_task(st)) }
          elsif atask = extract_task(t)
            job.tasks.create!(atask)
          end
        end
      end
    rescue
      logger.error("Failed to create new job and tasks: #{$!.message}\n\t#{$!.backtrace.join("\n\t")}")
      raise $!
    end
    job
  end

  def self.extract_sequence(t)
    if t.keys.first == 'sequence'
      t['sequence']
    elsif t.keys.include?('tasks')
      t
    else
      nil
    end
  end

  def self.extract_task(t)
    if t.keys.first == 'task'
      t['task']
    elsif t.keys.first == 'sequence'
      nil
    elsif t.keys.include?('tasks')
      nil
    else
      t
    end
  end

end
