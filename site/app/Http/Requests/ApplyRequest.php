<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Validation\Rule;

class ApplyRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    /** После ошибок возвращаем человека к форме, а не в начало страницы. */
    protected function getRedirectUrl(): string
    {
        return strtok($this->redirector->getUrlGenerator()->previous(), '#').'#apply';
    }

    /** @return array<string, mixed> */
    public function rules(): array
    {
        $codes = array_column(config('courses'), 'code');

        return [
            'name' => ['required', 'string', 'min:5', 'max:128', 'regex:/^[\p{L}\p{M}\s.\'\-]+$/u'],
            'phone' => ['required', 'string', 'max:32', 'regex:/^\+?[0-9\s\-()]{10,24}$/'],
            'email' => ['required', 'string', 'email:rfc', 'max:254'],
            'organization' => ['nullable', 'string', 'max:255'],
            'course' => ['required', 'string', Rule::in($codes)],
            'comment' => ['nullable', 'string', 'max:2000'],
            'consent' => ['accepted'],
            // Ловушка для ботов: поле скрыто, человек его не заполняет (см. ApplyController).
            'website' => ['nullable', 'string'],
        ];
    }

    /** @return array<string, string> */
    public function messages(): array
    {
        return [
            'required' => 'Заполните поле «:attribute».',
            'min' => 'Поле «:attribute» слишком короткое.',
            'max' => 'Поле «:attribute» слишком длинное.',
            'email' => 'Укажите корректный адрес электронной почты.',
            'name.regex' => 'Укажите имя буквами: фамилия, имя и отчество при наличии.',
            'phone.regex' => 'Укажите телефон в формате +7 900 123-45-67.',
            'course.in' => 'Выберите курс из списка.',
            'consent.accepted' => 'Для отправки заявки нужно согласие на обработку персональных данных.',
        ];
    }

    /** @return array<string, string> */
    public function attributes(): array
    {
        return [
            'name' => 'ФИО',
            'phone' => 'Телефон',
            'email' => 'E-mail',
            'organization' => 'Вуз или организация',
            'course' => 'Курс',
            'comment' => 'Комментарий',
        ];
    }

    protected function prepareForValidation(): void
    {
        foreach (['name', 'phone', 'email', 'organization', 'comment'] as $field) {
            if (is_string($this->input($field))) {
                $this->merge([$field => trim($this->input($field))]);
            }
        }
    }
}
